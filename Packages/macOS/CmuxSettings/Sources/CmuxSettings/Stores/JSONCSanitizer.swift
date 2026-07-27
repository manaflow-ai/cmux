import Foundation

/// Converts JSON-with-comments (JSONC) data into strict JSON.
///
/// The cmux config file uses JSONC so users can leave `// inline` and
/// `/* block */` comments and trailing commas — both rejected by
/// `JSONSerialization`. `JSONCSanitizer` strips those before parsing.
///
/// The sanitizer is a value type held by ``JSONConfigStore``. Inject a custom
/// instance for tests that want stricter or looser behavior; the default
/// initializer is enough for normal use.
public struct JSONCSanitizer: Sendable {
    /// Creates a sanitizer with the default behavior: strip `//` and
    /// `/* */` comments, strip trailing commas before `}` or `]`, accept UTF-8
    /// (with optional BOM), UTF-16 and UTF-32 input.
    public init() {}

    /// Strips JSONC extensions from ``data`` and returns strict JSON bytes.
    ///
    /// - Parameter data: JSONC-encoded payload.
    /// - Returns: A `Data` payload that `JSONSerialization` parses cleanly.
    /// - Throws: ``Failure/invalidTextEncoding`` if the byte sequence is not
    ///   one of the recognized encodings; ``Failure/unterminatedBlockComment``
    ///   if a `/*` block comment never closes.
    public func sanitize(_ data: Data) throws -> Data {
        let source = try decode(data: data)
        let withoutBOM = source.hasPrefix("\u{feff}") ? String(source.dropFirst()) : source
        let withoutComments = try stripComments(withoutBOM)
        let withoutTrailingCommas = stripTrailingCommas(withoutComments)
        return Data(withoutTrailingCommas.utf8)
    }

    /// Errors produced by ``sanitize(_:)``.
    public enum Failure: Error, Sendable {
        /// The byte sequence is not a recognized text encoding.
        case invalidTextEncoding
        /// A `/*` block comment was opened but never closed.
        case unterminatedBlockComment
    }

    private func decode(data: Data) throws -> String {
        if let encoding = detectedEncoding(for: data), let string = String(data: data, encoding: encoding) {
            return string
        }
        if let string = String(data: data, encoding: .utf8) { return string }
        throw Failure.invalidTextEncoding
    }

    private func detectedEncoding(for data: Data) -> String.Encoding? {
        let bytes = Array(data.prefix(4))
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        return nil
    }

    private func isLineTerminator(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar == "\n" || scalar == "\r"
    }

    private func stripComments(_ source: String) throws -> String {
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
                let next = source.index(after: index)
                if next < source.endIndex {
                    if source[next] == "/" {
                        index = source.index(after: next)
                        while index < source.endIndex, !isLineTerminator(source[index]) {
                            index = source.index(after: index)
                        }
                        continue
                    }
                    if source[next] == "*" {
                        index = source.index(after: next)
                        var didClose = false
                        while index < source.endIndex {
                            let following = source.index(after: index)
                            if source[index] == "*", following < source.endIndex, source[following] == "/" {
                                index = source.index(after: following)
                                didClose = true
                                break
                            }
                            index = following
                        }
                        guard didClose else { throw Failure.unterminatedBlockComment }
                        continue
                    }
                }
            }
            result.append(character)
            index = source.index(after: index)
        }
        return result
    }

    private func stripTrailingCommas(_ source: String) -> String {
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
                while lookahead < source.endIndex, source[lookahead].isWhitespace {
                    lookahead = source.index(after: lookahead)
                }
                if lookahead < source.endIndex, source[lookahead] == "}" || source[lookahead] == "]" {
                    index = source.index(after: index)
                    continue
                }
            }
            result.append(character)
            index = source.index(after: index)
        }
        return result
    }
}
