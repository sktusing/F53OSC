//
//  F53OSCMessage.m
//
//  Created by Siobhán Dougall on 1/17/11.
//
//  Copyright (c) 2011-2022 Figure 53 LLC, https://figure53.com
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//
//  Reference information: http://opensoundcontrol.org/spec-1_0-examples
//

#if !__has_feature(objc_arc)
#error This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

#import "F53OSCMessage.h"

#import "F53OSCServer.h"


NS_ASSUME_NONNULL_BEGIN

// Not trying to be perfect here; we just use unlikely characters.
NSString * const QUOTE_CHAR_TOKEN_PLAIN = @"⍁";        // QUOTATION MARK " (U+0022)
NSString * const QUOTE_CHAR_TOKEN_LEFT_DOUBLE = @"⍃";  // LEFT DOUBLE QUOTATION MARK “ (U+201C)
NSString * const QUOTE_CHAR_TOKEN_RIGHT_DOUBLE = @"⍄"; // RIGHT DOUBLE QUOTATION MARK ” (U+201D)

#pragma mark - NSString category

@interface NSString (F53OSCMessage)
- (NSString *)escapedCharacterTokenizedString;
- (NSString *)detokenizedUnescapedString;
@end

@implementation NSString (F53OSCMessage)

- (NSString *)escapedCharacterTokenizedString
{
    NSString *string = self;

    string = [string stringByReplacingOccurrencesOfString:@"\\\"" withString:QUOTE_CHAR_TOKEN_PLAIN];
    string = [string stringByReplacingOccurrencesOfString:@"\\\u201C" withString:QUOTE_CHAR_TOKEN_LEFT_DOUBLE];
    string = [string stringByReplacingOccurrencesOfString:@"\\\u201D" withString:QUOTE_CHAR_TOKEN_RIGHT_DOUBLE];

    return string;
}

- (NSString *)detokenizedUnescapedString
{
    NSString *string = self;

    string = [string stringByReplacingOccurrencesOfString:QUOTE_CHAR_TOKEN_PLAIN withString:@"\""];
    string = [string stringByReplacingOccurrencesOfString:QUOTE_CHAR_TOKEN_LEFT_DOUBLE withString:@"\u201C"];
    string = [string stringByReplacingOccurrencesOfString:QUOTE_CHAR_TOKEN_RIGHT_DOUBLE withString:@"\u201D"];

    return string;
}

@end


@interface F53OSCMessage ()

@property (strong, nullable) NSArray<NSString *> *addressPartsCache;

@end

@implementation F53OSCMessage

static NSCharacterSet *LEGAL_ADDRESS_CHARACTERS = nil;
static NSCharacterSet *LEGAL_METHOD_CHARACTERS = nil;
static NSCharacterSet *QUOTATION_MARK_CHARACTERS = nil;
static NSNumberFormatter *NUMBER_FORMATTER = nil;

+ (void) initialize
{
    if ( !LEGAL_ADDRESS_CHARACTERS )
    {
        NSString *legalAddressChars = [NSString stringWithFormat:@"%@/*?[]{,}", [F53OSCServer validCharsForOSCMethod]];
        LEGAL_ADDRESS_CHARACTERS = [NSCharacterSet characterSetWithCharactersInString:legalAddressChars];
        LEGAL_METHOD_CHARACTERS = [NSCharacterSet characterSetWithCharactersInString:[F53OSCServer validCharsForOSCMethod]];

        // Unless escaped with a `\`, +messageWithString: interprets all characters in this set as plain " (U+0022) quotation marks:
        // " plain (U+0022), “ curly left double (U+201C), ” curly right double (U+201D)
        QUOTATION_MARK_CHARACTERS = [NSCharacterSet characterSetWithCharactersInString:@"\"\u201C\u201D"];
    }
    if ( !NUMBER_FORMATTER )
    {
        NUMBER_FORMATTER = [[NSNumberFormatter alloc] init];
        NUMBER_FORMATTER.allowsFloats = YES;
        NUMBER_FORMATTER.locale = [NSLocale autoupdatingCurrentLocale];
    }
}

+ (BOOL) supportsSecureCoding
{
    return YES;
}

+ (BOOL) legalAddressComponent:(nullable NSString *)addressComponent
{
    if ( addressComponent == nil )
        return NO;
    
    if ( [LEGAL_ADDRESS_CHARACTERS isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:addressComponent]] )
    {
        if ( [addressComponent length] >= 1 )
            return YES;
    }
    
    return NO;
}

+ (BOOL) legalAddress:(nullable NSString *)address
{
    if ( address == nil )
        return NO;
    
    if ( [LEGAL_ADDRESS_CHARACTERS isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:address]] )
    {
        if ( [address length] >= 1 && [address characterAtIndex:0] == '/' )
            return YES;
    }
    
    return NO;
}

+ (BOOL) legalMethod:(nullable NSString *)method
{
    if ( method == nil )
        return NO;
    
    if ( [LEGAL_METHOD_CHARACTERS isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:method]] )
        return YES;
    else
        return NO;
}

+ (nullable F53OSCMessage *) messageWithString:(NSString *)qscString
{
    if ( qscString == nil )
        return nil;
    
    qscString = [qscString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if ( [qscString isEqualToString:@""] )
        return nil;
    
    // Pull out address.
    NSString *address = [qscString componentsSeparatedByString:@" "].firstObject;
    if ( ![self legalAddress:address] )
    {
        // Note: We'll return here if caller tried to parse a QSC bundle string as a message string;
        //       The # character used in the #bundle string is not a legal address character.
        return nil;
    }
    
    // Pull out arguments...
    NSString *qscArgString = [qscString substringFromIndex:[address length]];
    NSArray<id> *arguments = [self argumentsWithString:qscArgString];

    return [F53OSCMessage messageWithAddressPattern:(NSString * _Nonnull)address arguments:arguments];
}

+ (NSArray<id> *)argumentsWithString:(NSString *)argString
{
    // Create a working copy.
    NSString *workingArguments = argString;

    // Place a token for each escaped quotation mark character.
    workingArguments = [workingArguments escapedCharacterTokenizedString];

    // After all escaped quotation mark characters are tokenized, conform all allowed quotation mark characters to the plain " (U+0022) mark.
    workingArguments = [[workingArguments componentsSeparatedByCharactersInSet:QUOTATION_MARK_CHARACTERS] componentsJoinedByString:@"\""];

    // The remaining " characters signify quoted string arguments; they should be paired up.
    NSArray<NSString *> *splitOnQuotes = [workingArguments componentsSeparatedByString:@"\""];
    if ( [splitOnQuotes count] % 2 != 1 )
        return @[]; // not matching quotes

    NSString *QUOTED_STRING_TOKEN = @"⍂"; // not trying to be perfect here; we just use an unlikely character
    NSMutableArray<NSString *> *quotedStrings = [NSMutableArray array];
    for ( NSUInteger i = 1; i < [splitOnQuotes count]; i += 2 )
    {
        // Pull out each quoted string, which will be at each odd index.
        NSString *quotedString = [splitOnQuotes objectAtIndex:i];
        [quotedStrings addObject:quotedString];
        
        // Place a token for the quote we just pulled.
        NSString *extractedQuote = [NSString stringWithFormat:@"\"%@\"", quotedString];
        NSRange rangeOfFirstOccurrence = [workingArguments rangeOfString:extractedQuote];
        if ( rangeOfFirstOccurrence.location == NSNotFound || rangeOfFirstOccurrence.length == 0 )
            continue;

        workingArguments = [workingArguments stringByReplacingOccurrencesOfString:extractedQuote
                                                                       withString:QUOTED_STRING_TOKEN
                                                                          options:0
                                                                            range:rangeOfFirstOccurrence];
    }
    
    // The working arguments have now been tokenized enough to process.
    // Expand the tokens and store the final array of arguments.
    NSMutableArray<id> *finalArgs = [NSMutableArray array];
    NSArray<NSString *> *tokenArgs = [workingArguments componentsSeparatedByString:@" "];
    NSUInteger quotedStringIndex = 0;
    for ( NSString *arg in tokenArgs )
    {
        if ( [arg isEqual:@""] ) // artifact of componentsSeparatedByString
            continue;
        
        if ( [arg containsString:QUOTED_STRING_TOKEN] )
        {
            // Quoted string arguments should be separated by spaces, so we should only have QUOTED_STRING_TOKEN here.
            // If `arg` has any additional characters either before or after QUOTED_STRING_TOKEN, parsing fails.
            // i.e. if `workingArguments` has quoted strings that are not properly separated by spaces.
            if ( [arg isEqual:QUOTED_STRING_TOKEN] == NO )
                return @[];

            NSString *quotedString = [quotedStrings objectAtIndex:quotedStringIndex];
            NSString *detokenized = [quotedString detokenizedUnescapedString];
            [finalArgs addObject:detokenized]; // quoted OSC string
            quotedStringIndex++;
        }
        else if ( [arg isEqual:QUOTE_CHAR_TOKEN_PLAIN] ||
                 [arg isEqual:QUOTE_CHAR_TOKEN_LEFT_DOUBLE] ||
                 [arg isEqual:QUOTE_CHAR_TOKEN_RIGHT_DOUBLE] )
        {
            [finalArgs addObject:[arg detokenizedUnescapedString]]; // single character OSC string - 's'
        }
        else if ( [arg hasPrefix:@"#blob"] )
        {
            NSString *encodedBlob = [arg substringFromIndex:5]; // strip "#blob"
            if ( [encodedBlob isEqual:@""] )
                continue;
            
            NSData *blob = [[NSData alloc] initWithBase64EncodedString:encodedBlob options:0];
            if ( blob )
            {
                [finalArgs addObject:blob];    // OSC blob - 'b'
            }
            else
            {
                NSLog( @"Error: F53OSCMessage: Unable to decode base64 encoded string: %@", encodedBlob );
            }
        }
        else if ( [arg isEqualToString:@"\\T"] )
        {
            [finalArgs addObject:[F53OSCValue oscTrue]];    // 'T'
        }
        else if ( [arg isEqualToString:@"\\F"] )
        {
            [finalArgs addObject:[F53OSCValue oscFalse]];   // 'F'
        }
        else if ( [arg isEqualToString:@"\\N"] )
        {
            [finalArgs addObject:[F53OSCValue oscNull]];    // 'N'
        }
        else if ( [arg isEqualToString:@"\\I"] )
        {
            [finalArgs addObject:[F53OSCValue oscImpulse]]; // 'I'
        }
        else
        {
#ifdef TESTING
            if ( [[NSUserDefaults standardUserDefaults] objectForKey:@"com.figure53.f53osc.testingLocaleIdentifier"] )
            {
                NSString *identifier = [[NSUserDefaults standardUserDefaults] objectForKey:@"com.figure53.f53osc.testingLocaleIdentifier"];
                NUMBER_FORMATTER.locale = [NSLocale localeWithLocaleIdentifier:identifier];
            }
#endif
            NSNumber *number = [NUMBER_FORMATTER numberFromString:arg];
            if ( number != nil )
            {
                // unquoted argument was successfully formatted as a number
                [finalArgs addObject:number];  // OSC int or float - 'i' or 'f'
            }
            else
            {
                // If all other conditions above were not satisfied,
                // handle unquoted argument as a string anyway.
                NSString *detokenized = [arg detokenizedUnescapedString];
                [finalArgs addObject:detokenized]; // unquoted OSC string - 's'
            }
        }
    }

    return [NSArray arrayWithArray:finalArgs];
}

+ (F53OSCMessage *) messageWithAddressPattern:(NSString *)addressPattern
                                    arguments:(NSArray<id> *)arguments
{
    return [F53OSCMessage messageWithAddressPattern:addressPattern arguments:arguments replySocket:nil];
}

+ (F53OSCMessage *) messageWithAddressPattern:(NSString *)addressPattern 
                                    arguments:(NSArray<id> *)arguments
                                  replySocket:(nullable F53OSCSocket *)replySocket
{
    F53OSCMessage *msg = [F53OSCMessage new];
    msg.addressPattern = addressPattern;
    msg.arguments = arguments;
    msg.replySocket = replySocket;
    return msg;
}

#pragma mark -

- (instancetype) init
{
    self = [super init];
    if ( self )
    {
        self.addressPattern = @"/";
        self.addressPartsCache = nil;
        self.typeTagString = @",";
        self.arguments = [NSArray array];
        self.userData = nil;
    }
    return self;
}

- (void) encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:self.addressPattern forKey:@"addressPattern"];
    [coder encodeObject:self.typeTagString forKey:@"typeTagString"];
    [coder encodeObject:self.arguments forKey:@"arguments"];
}

- (nullable instancetype) initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if ( self )
    {
        [self setAddressPattern:[coder decodeObjectOfClass:[NSString class] forKey:@"addressPattern"]];
        [self setTypeTagString:[coder decodeObjectOfClass:[NSString class] forKey:@"typeTagString"]];
        [self setArguments:[coder decodeObjectOfClasses:[NSSet setWithObjects:[NSArray class], [NSString class], [NSNumber class], [NSData class], [F53OSCValue class], nil] forKey:@"arguments"]];
    }
    return self;
}

- (id) copyWithZone:(nullable NSZone *)zone
{
    F53OSCMessage *copy = [super copyWithZone:zone];
    copy.addressPattern = [self.addressPattern copyWithZone:zone];
    copy.typeTagString = [self.typeTagString copyWithZone:zone];
    copy.arguments = [self.arguments copyWithZone:zone];
    copy.userData = [self.userData copyWithZone:zone];
    return copy;
}

- (NSString *) description
{
    NSMutableString *description = [NSMutableString stringWithString:self.addressPattern];
    for ( id arg in self.arguments )
    {
        if ( [[arg class] isSubclassOfClass:[NSString class]] )
            [description appendFormat:@" \"%@\"", [arg description]]; // make strings clear in debug logs
        else if ( [arg isEqual:[F53OSCValue oscTrue]] )
            [description appendString:@" \\T"];                       // make True clear in debug logs
        else if ( [arg isEqual:[F53OSCValue oscFalse]] )
            [description appendString:@" \\F"];                       // make False clear in debug logs
        else if ( [arg isEqual:[F53OSCValue oscNull]] )
            [description appendString:@" \\N"];                       // make Null clear in debug logs
        else if ( [arg isEqual:[F53OSCValue oscImpulse]] )
            [description appendString:@" \\I"];                       // make Impulse clear in debug logs
        else
            [description appendFormat:@" %@", [arg description]];
    }
    return [NSString stringWithString:description];
}

- (BOOL) isEqual:(nullable id)object
{
    if ( [object isMemberOfClass:[self class]] )
    {
        F53OSCMessage *otherObject = object;
        if (   [otherObject.addressPattern isEqualToString:self.addressPattern]
            && [otherObject.arguments isEqualToArray:self.arguments] )
        {
            return YES;
        }
    }
    return NO;
}

#pragma mark -

- (void) setAddressPattern:(NSString *)newAddressPattern
{
    if ( newAddressPattern == nil ||
        [newAddressPattern length] == 0 ||
        ![[NSCharacterSet characterSetWithCharactersInString:@"/!"] characterIsMember:[newAddressPattern characterAtIndex:0]] )
    {
        return;
    }
    
    _addressPattern = [newAddressPattern copy];
    self.addressPartsCache = nil;
}

- (void) setArguments:(NSArray<id> *)argArray
{
    NSMutableArray<id> *newArgs = [NSMutableArray array];
    NSMutableString *newTypes = [NSMutableString stringWithString:@","];
    for ( id obj in argArray )
    {
        if ( [obj isKindOfClass:[NSString class]] )
        {
            [newTypes appendString:@"s"]; // OSC string - 's'
            [newArgs addObject:obj];
        }
        else if ( [obj isKindOfClass:[NSData class]] )
        {
            [newTypes appendString:@"b"]; // OSC blob - 'b'
            [newArgs addObject:obj];
        }
        else if ( [obj isKindOfClass:[NSNumber class]] )
        {
            CFNumberType numberType = CFNumberGetType( (CFNumberRef)obj );
            switch ( numberType )
            {
                case kCFNumberSInt8Type:
                case kCFNumberSInt16Type:
                case kCFNumberSInt32Type:
                case kCFNumberSInt64Type:
                case kCFNumberCharType:
                case kCFNumberShortType:
                case kCFNumberIntType:
                case kCFNumberLongType:
                case kCFNumberLongLongType:
                case kCFNumberNSIntegerType:
                    [newTypes appendString:@"i"]; // OSC integer - 'i'
                    break;
                case kCFNumberFloat32Type:
                case kCFNumberFloat64Type:
                case kCFNumberFloatType:
                case kCFNumberDoubleType:
                case kCFNumberCGFloatType:
                    [newTypes appendString:@"f"]; // OSC float - 'f'
                    break;
                default:
                    NSLog( @"Number with unrecognized type: %i (value = %@).", (int)numberType, obj );
                    continue;
            }
            [newArgs addObject:obj];
        }
        else if ( [obj isEqual:[F53OSCValue oscTrue]] )
        {
            [newTypes appendString:@"T"]; // OSC true - 'T'
            [newArgs addObject:obj];
        }
        else if ( [obj isEqual:[F53OSCValue oscFalse]] )
        {
            [newTypes appendString:@"F"]; // OSC false - 'F'
            [newArgs addObject:obj];
        }
        else if ( [obj isEqual:[F53OSCValue oscNull]] )
        {
            [newTypes appendString:@"N"]; // OSC null - 'N'
            [newArgs addObject:obj];
        }
        else if ( [obj isEqual:[F53OSCValue oscImpulse]] )
        {
            [newTypes appendString:@"I"]; // OSC impulse - 'I'
            [newArgs addObject:obj];
        }
    }
    self.typeTagString = [newTypes copy];
    _arguments = [newArgs copy];
}

- (NSArray<NSString *> *) addressParts
{
    if ( self.addressPartsCache == nil )
    {
        if ( self.addressPattern.length > 0 && [self.addressPattern characterAtIndex:0] == '!' )
        {
            /* This method currently only works on real OSC messages starting with /, not F53OSC Control messages starting with !
               and would need to be updated if we want to parse parts of control message addresses. */
            NSLog(@"Error: trying to compute addressParts of an F53OSC control message is currently unsupported");
        }
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithArray:[self.addressPattern componentsSeparatedByString:@"/"]];
        [parts removeObjectAtIndex:0];
        self.addressPartsCache = [NSArray arrayWithArray:parts];
    }
    return self.addressPartsCache;
}

- (NSData *) packetData
{
    NSMutableData *result = [[self.addressPattern oscStringData] mutableCopy];
    
    [result appendData:[self.typeTagString oscStringData]];
    
    for ( id obj in self.arguments )
    {
        if ( [obj isKindOfClass:[NSString class]] )
        {
            [result appendData:[(NSString *)obj oscStringData]]; // 's'
        }
        else if ( [obj isKindOfClass:[NSData class]] )
        {
            [result appendData:[(NSData *)obj oscBlobData]]; // 'b'
        }
        else if ( [obj isKindOfClass:[NSNumber class]] )
        {
            SInt32 intValue;
            CFNumberType numberType = CFNumberGetType( (CFNumberRef)obj );
            switch ( numberType )
            {
                case kCFNumberSInt8Type:
                case kCFNumberSInt16Type:
                case kCFNumberSInt32Type:
                case kCFNumberSInt64Type:
                case kCFNumberCharType:
                case kCFNumberShortType:
                case kCFNumberIntType:
                case kCFNumberLongType:
                case kCFNumberLongLongType:
                case kCFNumberNSIntegerType:
                    intValue = [(NSNumber *)obj oscIntValue]; // 'i'
                    [result appendBytes:&intValue length:sizeof( SInt32 )];
                    break;
                case kCFNumberFloat32Type:
                case kCFNumberFloat64Type:
                case kCFNumberFloatType:
                case kCFNumberDoubleType:
                case kCFNumberCGFloatType:
                    intValue = [(NSNumber *)obj oscFloatValue]; // 'f'
                    [result appendBytes:&intValue length:sizeof( SInt32 )];
                    break;
                default:
                    NSLog( @"Number with unrecognized type: %i (value = %@).", (int)numberType, obj );
                    continue;
            }
        }
        else if ( [obj isKindOfClass:[F53OSCValue class]] )
        {
            // no bytes are allocated for 'T', 'F', 'I', or 'N'
        }
    }
    
    return result;
}

- (NSString *) asQSC
{
    NSMutableString *qscString = [NSMutableString stringWithString:self.addressPattern];
    for ( id arg in self.arguments )
    {
        if ( [arg isKindOfClass:[NSString class]] ) // 's'
        {
            NSString *escapedQuotesArg = [arg stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            [qscString appendFormat:@" \"%@\"", escapedQuotesArg];
        }
        else if ( [arg isKindOfClass:[NSNumber class]] ) // 'i' or 'f'
        {
            CFNumberType numberType = CFNumberGetType( (CFNumberRef)arg );
            switch ( numberType )
            {
                case kCFNumberSInt8Type:
                case kCFNumberSInt16Type:
                case kCFNumberSInt32Type:
                case kCFNumberSInt64Type:
                case kCFNumberCharType:
                case kCFNumberShortType:
                case kCFNumberIntType:
                case kCFNumberLongType:
                case kCFNumberLongLongType:
                case kCFNumberNSIntegerType:
                    [qscString appendFormat:@" %ld", ((NSNumber *)arg).longValue]; // 'i'
                    break;
                case kCFNumberFloat32Type:
                case kCFNumberFloat64Type:
                case kCFNumberFloatType:
                case kCFNumberDoubleType:
                case kCFNumberCGFloatType:
                    [qscString appendFormat:@" %@", arg]; // 'f'
                    break;
                default:
                    NSLog( @"Number with unrecognized type: %i (value = %@).", (int)numberType, arg );
                    [qscString appendFormat:@" %@", arg];
                    break;
            }
        }
        else if ( [arg isKindOfClass:[NSData class]] ) // 'b'
        {
            [qscString appendFormat:@" #blob%@", [arg base64EncodedStringWithOptions:0]];
        }
        else if ( [arg isEqual:[F53OSCValue oscTrue]] ) // 'T'
        {
            [qscString appendString:@" \\T"];
        }
        else if ( [arg isEqual:[F53OSCValue oscFalse]] ) // 'F'
        {
            [qscString appendString:@" \\F"];
        }
        else if ( [arg isEqual:[F53OSCValue oscNull]] ) // 'N'
        {
            [qscString appendString:@" \\N"];
        }
        else if ( [arg isEqual:[F53OSCValue oscImpulse]] ) // 'I'
        {
            [qscString appendString:@" \\I"];
        }
    }
    return [NSString stringWithString:qscString];
}

@end

NS_ASSUME_NONNULL_END
