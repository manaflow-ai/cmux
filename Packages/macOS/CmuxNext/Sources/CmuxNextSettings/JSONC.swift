import Foundation

/// JSON with comments, the cmux.json authoring format: `//` and `/* */`
/// comments and trailing commas are allowed. Reads strip them. The app never
/// edits the text: the daemon's settings owner (cmux-tui `cmux-config`
/// `jsonc`) writes the file in place so comments, key order and formatting
/// survive (``SettingsFileWriter``).
public struct JSONC {
    public init() {}
    public enum Failure: Error, Sendable, Equatable {
        case unterminatedComment
        case unterminatedString
        case malformed(offset: Int)
    }

    // MARK: - Reading

    /// Strict JSON text for `source`: comments removed, trailing commas
    /// dropped. String contents are untouched.
    public static func strip(_ source: String) throws -> String {
        let bytes = Array(source.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let end = try stringEnd(bytes, from: index)
                output.append(contentsOf: bytes[index..<end])
                index = end
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count,
                      bytes[index + 1] == UInt8(ascii: "/") || bytes[index + 1] == UInt8(ascii: "*") {
                let end = try commentEnd(bytes, from: index)
                // Keep line structure so error offsets stay meaningful.
                output.append(contentsOf: bytes[index..<end].filter { $0 == 0x0A })
                index = end
            } else if byte == UInt8(ascii: ",") {
                let next = try skipTrivia(bytes, from: index + 1)
                if next < bytes.count, bytes[next] == UInt8(ascii: "}") || bytes[next] == UInt8(ascii: "]") {
                    index += 1
                } else {
                    output.append(byte)
                    index += 1
                }
            } else {
                output.append(byte)
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Parses JSONC text. An empty or comment-only document is an empty object.
    public static func parse(_ source: String) throws -> JSONValue {
        let strict = try strip(source)
        if strict.allSatisfy(\.isWhitespace) { return .object([:]) }
        return try JSONValue.parse(Data(strict.utf8))
    }

    // MARK: - Structure

    struct Member {
        var key: String
        var keyStart: Int
        var node: Node
    }

    struct ObjectNode {
        var members: [Member]
    }

    enum Node {
        case object(ObjectNode)
        case scalar
    }

    static func parseRoot(_ bytes: [UInt8]) throws -> Node? {
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        index = try skipTrivia(bytes, from: index)
        guard index < bytes.count else { return nil }
        let (node, end) = try parseValue(bytes, at: index)
        guard try skipTrivia(bytes, from: end) == bytes.count else { throw Failure.malformed(offset: end) }
        return node
    }

    private static func parseValue(_ bytes: [UInt8], at start: Int) throws -> (Node, Int) {
        guard start < bytes.count else { throw Failure.malformed(offset: start) }
        switch bytes[start] {
        case UInt8(ascii: "{"):
            return try parseObject(bytes, at: start)
        case UInt8(ascii: "["):
            var index = try skipTrivia(bytes, from: start + 1)
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { return (.scalar, index + 1) }
            // wakeup-allow: parser loop over a finite in-memory buffer (no IO); every pass consumes input
            while true {
                let (_, end) = try parseValue(bytes, at: index)
                index = try skipTrivia(bytes, from: end)
                guard index < bytes.count else { throw Failure.malformed(offset: index) }
                if bytes[index] == UInt8(ascii: ",") {
                    index = try skipTrivia(bytes, from: index + 1)
                    if index < bytes.count, bytes[index] == UInt8(ascii: "]") { return (.scalar, index + 1) }
                } else if bytes[index] == UInt8(ascii: "]") {
                    return (.scalar, index + 1)
                } else {
                    throw Failure.malformed(offset: index)
                }
            }
        case UInt8(ascii: "\""):
            return (.scalar, try stringEnd(bytes, from: start))
        default:
            var end = start
            while end < bytes.count, !isDelimiter(bytes[end]) { end += 1 }
            guard end > start else { throw Failure.malformed(offset: start) }
            return (.scalar, end)
        }
    }

    private static func parseObject(_ bytes: [UInt8], at open: Int) throws -> (Node, Int) {
        var members: [Member] = []
        var index = try skipTrivia(bytes, from: open + 1)
        // wakeup-allow: parser loop over a finite in-memory buffer (no IO); every pass consumes input
        while true {
            guard index < bytes.count else { throw Failure.malformed(offset: index) }
            if bytes[index] == UInt8(ascii: "}") {
                return (.object(ObjectNode(members: members)), index + 1)
            }
            guard bytes[index] == UInt8(ascii: "\"") else { throw Failure.malformed(offset: index) }
            let keyEnd = try stringEnd(bytes, from: index)
            let keyText = String(decoding: bytes[index..<keyEnd], as: UTF8.self)
            let key = (try? JSONValue.parse(Data(keyText.utf8)))?.stringValue ?? ""
            var cursor = try skipTrivia(bytes, from: keyEnd)
            guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") else { throw Failure.malformed(offset: cursor) }
            cursor = try skipTrivia(bytes, from: cursor + 1)
            let (node, valueEnd) = try parseValue(bytes, at: cursor)
            members.append(Member(key: key, keyStart: index, node: node))
            index = try skipTrivia(bytes, from: valueEnd)
            guard index < bytes.count else { throw Failure.malformed(offset: index) }
            if bytes[index] == UInt8(ascii: ",") {
                index = try skipTrivia(bytes, from: index + 1)
            } else if bytes[index] != UInt8(ascii: "}") {
                throw Failure.malformed(offset: index)
            }
        }
    }

    // MARK: - Lexing helpers

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: "/"),
             UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
            true
        default:
            false
        }
    }

    private static func stringEnd(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return index + 1
            default: index += 1
            }
        }
        throw Failure.unterminatedString
    }

    private static func commentEnd(_ bytes: [UInt8], from start: Int) throws -> Int {
        if bytes[start + 1] == UInt8(ascii: "/") {
            var index = start + 2
            while index < bytes.count, bytes[index] != 0x0A { index += 1 }
            return index
        }
        var index = start + 2
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") { return index + 2 }
            index += 1
        }
        throw Failure.unterminatedComment
    }

    private static func skipTrivia(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count,
                      bytes[index + 1] == UInt8(ascii: "/") || bytes[index + 1] == UInt8(ascii: "*") {
                index = try commentEnd(bytes, from: index)
            } else {
                break
            }
        }
        return index
    }
}
