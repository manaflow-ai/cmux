import Foundation

enum JSONCParser {
    static func preprocess(data: Data) throws -> Data {
        let source = try sourceString(from: data)
        let withoutBOM = source.hasPrefix("\u{feff}") ? String(source.dropFirst()) : source
        let stripped = try stripComments(from: withoutBOM)
        let normalized = stripTrailingCommas(from: stripped)
        return Data(normalized.utf8)
    }

    private static func sourceString(from data: Data) throws -> String {
        if let encoding = detectedJSONEncoding(for: data),
           let source = String(data: data, encoding: encoding) {
            return source
        }
        if let source = String(data: data, encoding: .utf8) {
            return source
        }

        var convertedString: NSString?
        var usedLossyConversion = ObjCBool(false)
        let encoding = NSString.stringEncoding(
            for: data,
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
            return convertedString as String
        }
        if encoding != 0, !usedLossyConversion.boolValue {
            let stringEncoding = String.Encoding(rawValue: encoding)
            if let source = String(data: data, encoding: stringEncoding) {
                return source
            }
        }
        throw JSONCError.invalidTextEncoding
    }

    private static func detectedJSONEncoding(for data: Data) -> String.Encoding? {
        let bytes = Array(data.prefix(4))
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

    private static func stripComments(from source: String) throws -> String {
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
                        while index < source.endIndex && source[index] != "\n" {
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

    private static func stripTrailingCommas(from source: String) -> String {
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

            if character == "," {
                var lookahead = source.index(after: index)
                while lookahead < source.endIndex && source[lookahead].isWhitespace {
                    lookahead = source.index(after: lookahead)
                }
                if lookahead < source.endIndex && (source[lookahead] == "}" || source[lookahead] == "]") {
                    index = source.index(after: index)
                    continue
                }
            }

            result.append(character)
            index = source.index(after: index)
        }

        return result
    }

    private enum JSONCError: LocalizedError {
        case invalidTextEncoding
        case unterminatedBlockComment

        var errorDescription: String? {
            switch self {
            case .invalidTextEncoding:
                return "config file text encoding is not supported"
            case .unterminatedBlockComment:
                return "unterminated block comment"
            }
        }
    }
}
