public import Foundation

/// JSONC (JSON-with-comments) preprocessing for cmux config payloads.
///
/// cmux config files use JSONC so users can leave `// inline` and `/* block */`
/// comments and trailing commas, all of which `JSONSerialization` rejects. These
/// `Data` operations decode the bytes to text (sniffing UTF-8/16/32 and BOMs),
/// strip the JSONC extensions, and return strict JSON bytes. Unlike the lenient
/// ``JSONCSanitizer`` used by the settings store, this path is strict: a trailing
/// comma in an otherwise-empty container is rejected rather than silently dropped.
extension Data {
    /// Strips comments and trailing commas from JSONC bytes, returning strict JSON.
    ///
    /// - Returns: A `Data` payload that `JSONSerialization` parses cleanly.
    /// - Throws: when the bytes are not a recognized text encoding, a `/*` block
    ///   comment never closes, or a trailing comma appears in an empty container.
    public func jsoncPreprocessed() throws -> Data {
        let source = try jsoncSourceText()
        let withoutBOM = source.hasPrefix("\u{feff}") ? String(source.dropFirst()) : source
        let stripped = try withoutBOM.jsoncCommentsStripped()
        let normalized = try stripped.jsoncTrailingCommasStripped()
        return Data(normalized.utf8)
    }

    /// Decodes the receiver to text, returning the detected (or sniffed) encoding.
    ///
    /// - Throws: when no recognized encoding decodes the bytes losslessly.
    public func jsoncSource() throws -> (text: String, encoding: String.Encoding) {
        if let encoding = detectedJSONTextEncoding(),
           let source = String(data: self, encoding: encoding) {
            return (source, encoding)
        }
        if let source = String(data: self, encoding: .utf8) {
            return (source, .utf8)
        }

        var convertedString: NSString?
        var usedLossyConversion = ObjCBool(false)
        let encoding = NSString.stringEncoding(
            for: self,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.utf8.rawValue,
                    String.Encoding.utf16BigEndian.rawValue,
                    String.Encoding.utf16LittleEndian.rawValue,
                    String.Encoding.utf32BigEndian.rawValue,
                    String.Encoding.utf32LittleEndian.rawValue,
                ],
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
            ],
            convertedString: &convertedString,
            usedLossyConversion: &usedLossyConversion
        )

        if let convertedString, !usedLossyConversion.boolValue {
            let stringEncoding = encoding == 0 ? String.Encoding.utf8 : String.Encoding(rawValue: encoding)
            return (convertedString as String, stringEncoding)
        }
        if encoding != 0, !usedLossyConversion.boolValue {
            let stringEncoding = String.Encoding(rawValue: encoding)
            if let string = String(data: self, encoding: stringEncoding) {
                return (string, stringEncoding)
            }
        }
        throw JSONCError.invalidTextEncoding
    }

    private func jsoncSourceText() throws -> String {
        try jsoncSource().text
    }

    private func detectedJSONTextEncoding() -> String.Encoding? {
        let bytes = Array(prefix(4))
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        guard bytes.count >= 4 else { return nil }

        switch (bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0) {
        case (true, true, true, false):
            return .utf32BigEndian
        case (false, true, true, true):
            return .utf32LittleEndian
        case (true, false, true, false):
            return .utf16BigEndian
        case (false, true, false, true):
            return .utf16LittleEndian
        default:
            return nil
        }
    }
}

extension String {
    fileprivate func jsoncCommentsStripped() throws -> String {
        let source = self
        var result = ""
        var index = source.startIndex
        var inString = false
        var isEscaped = false

        while index < source.endIndex {
            let character = source[index]

            if inString {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "/" {
                let nextIndex = source.index(after: index)
                if nextIndex < source.endIndex {
                    let next = source[nextIndex]
                    if next == "/" {
                        index = source.index(after: nextIndex)
                        while index < source.endIndex && !source[index].isJSONCLineTerminator {
                            index = source.index(after: index)
                        }
                        continue
                    }
                    if next == "*" {
                        index = source.index(after: nextIndex)
                        var didClose = false
                        while index < source.endIndex {
                            let current = source[index]
                            let followingIndex = source.index(after: index)
                            if current == "*" && followingIndex < source.endIndex && source[followingIndex] == "/" {
                                index = source.index(after: followingIndex)
                                didClose = true
                                break
                            }
                            index = followingIndex
                        }
                        guard didClose else {
                            throw JSONCError.unterminatedBlockComment
                        }
                        continue
                    }
                }
            }

            result.append(character)
            index = source.index(after: index)
        }

        return result
    }

    fileprivate func jsoncTrailingCommasStripped() throws -> String {
        let source = self
        var result = ""
        var index = source.startIndex
        var inString = false
        var isEscaped = false
        var lastSignificantCharacter: Character?

        while index < source.endIndex {
            let character = source[index]

            if inString {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                    lastSignificantCharacter = character
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "," {
                var lookahead = source.index(after: index)
                while lookahead < source.endIndex && source[lookahead].isWhitespace {
                    lookahead = source.index(after: lookahead)
                }
                if lookahead < source.endIndex && (source[lookahead] == "}" || source[lookahead] == "]") {
                    if lastSignificantCharacter == nil ||
                        lastSignificantCharacter == "," ||
                        lastSignificantCharacter == "{" ||
                        lastSignificantCharacter == "[" ||
                        lastSignificantCharacter == ":" {
                        throw JSONCError.invalidTrailingComma
                    }
                    index = source.index(after: index)
                    continue
                }
            }

            result.append(character)
            if !character.isWhitespace {
                lastSignificantCharacter = character
            }
            index = source.index(after: index)
        }

        return result
    }
}

private enum JSONCError: LocalizedError {
    case invalidTextEncoding
    case invalidTrailingComma
    case unterminatedBlockComment

    var errorDescription: String? {
        switch self {
        case .invalidTextEncoding:
            return "config file text encoding is not supported"
        case .invalidTrailingComma:
            return "invalid trailing comma"
        case .unterminatedBlockComment:
            return "unterminated block comment"
        }
    }
}
