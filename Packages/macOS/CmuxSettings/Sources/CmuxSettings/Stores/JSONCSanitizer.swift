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
        let withoutComments = try stripComments(Array(withoutBOM.utf8))
        let withoutTrailingCommas = stripTrailingCommas(withoutComments)
        return Data(withoutTrailingCommas)
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

    private func stripComments(_ source: [UInt8]) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(source.count)
        var index = 0
        var inString = false
        var isEscaped = false
        while index < source.count {
            let byte = source[index]
            if inString {
                result.append(byte)
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\"") {
                inString = true
                result.append(byte)
                index += 1
                continue
            }
            if byte == UInt8(ascii: "/"), index + 1 < source.count {
                switch source[index + 1] {
                case UInt8(ascii: "/"):
                    index += 2
                    while index < source.count {
                        let current = source[index]
                        if current == UInt8(ascii: "\n") || current == UInt8(ascii: "\r") {
                            break
                        }
                        index += 1
                    }
                    continue
                case UInt8(ascii: "*"):
                    index += 2
                    var didClose = false
                    while index + 1 < source.count {
                        if source[index] == UInt8(ascii: "*"), source[index + 1] == UInt8(ascii: "/") {
                            index += 2
                            didClose = true
                            break
                        }
                        index += 1
                    }
                    guard didClose else { throw Failure.unterminatedBlockComment }
                    continue
                default:
                    break
                }
            }
            result.append(byte)
            index += 1
        }
        return result
    }

    private func stripTrailingCommas(_ source: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(source.count)
        var index = 0
        var inString = false
        var isEscaped = false
        while index < source.count {
            let byte = source[index]
            if inString {
                result.append(byte)
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\"") {
                inString = true
                result.append(byte)
                index += 1
                continue
            }
            if byte == UInt8(ascii: ",") {
                var lookahead = index + 1
                while lookahead < source.count {
                    let scalar = utf8Scalar(in: source, at: lookahead)
                    guard scalar.value.properties.isWhitespace else { break }
                    lookahead += scalar.length
                }
                if lookahead < source.count,
                   source[lookahead] == UInt8(ascii: "}") || source[lookahead] == UInt8(ascii: "]") {
                    index += 1
                    continue
                }
            }
            result.append(byte)
            index += 1
        }
        return result
    }

    private func utf8Scalar(in bytes: [UInt8], at index: Int) -> (value: Unicode.Scalar, length: Int) {
        let first = bytes[index]
        if first < 0x80 { return (Unicode.Scalar(first), 1) }
        let length = first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
        let prefixMask = UInt8((1 << (7 - length)) - 1)
        var value = UInt32(first & prefixMask)
        for offset in 1..<length {
            value = value << 6 | UInt32(bytes[index + offset] & 0x3F)
        }
        return (Unicode.Scalar(value)!, length)
    }
}
