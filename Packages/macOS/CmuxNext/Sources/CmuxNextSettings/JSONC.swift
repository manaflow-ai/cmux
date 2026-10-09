import Foundation

/// JSON with comments, the cmux.json authoring format: `//` and `/* */`
/// comments and trailing commas are allowed. Reads strip them; writes edit
/// the source text in place so comments, key order, and formatting the user
/// wrote survive a `settings.set` (the same policy as the old app's
/// `JSONCPathEditor`).
public struct JSONC {
    public init() {}
    public enum Failure: Error, Sendable, Equatable {
        case unterminatedComment
        case unterminatedString
        case malformed(offset: Int)
        /// The document's root is not an object, so a key path cannot be set.
        case rootIsNotObject
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

    // MARK: - Editing

    /// `source` with the value at `path` set to `value`, creating
    /// intermediate objects as needed. Everything outside the edited value
    /// is preserved byte for byte.
    public static func setting(_ value: JSONValue, at path: [String], in source: String) throws -> String {
        precondition(!path.isEmpty, "path must not be empty")
        let bytes = Array(source.utf8)
        guard let root = try parseRoot(bytes) else {
            // Empty or comment-only file: write a fresh document after it.
            let document = JSONValue.nest(value, under: path).prettyText()
            let prefix = source.allSatisfy(\.isWhitespace) ? "" : source + (source.hasSuffix("\n") ? "" : "\n")
            return prefix + document + "\n"
        }
        guard case .object(let object) = root else { throw Failure.rootIsNotObject }
        var edits: [Edit] = []
        setting(value, at: path[...], in: object, bytes: bytes, edits: &edits)
        return apply(edits, to: bytes)
    }

    /// `source` with the member at `path` removed. Unchanged when absent.
    public static func removing(_ path: [String], in source: String) throws -> String {
        precondition(!path.isEmpty, "path must not be empty")
        let bytes = Array(source.utf8)
        guard let root = try parseRoot(bytes) else { return source }
        guard case .object(var object) = root else { throw Failure.rootIsNotObject }
        for key in path.dropLast() {
            guard let member = object.members.first(where: { $0.key == key }),
                  case .object(let child) = member.node else { return source }
            object = child
        }
        guard let index = object.members.firstIndex(where: { $0.key == path.last }) else { return source }
        return apply(removalEdits(memberAt: index, in: object, bytes: bytes), to: bytes)
    }

    // MARK: - Structure

    struct Member {
        var key: String
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int
        var node: Node
        /// Offset of the comma that follows the value, if any.
        var commaAfter: Int?
    }

    struct ObjectNode {
        var open: Int
        var close: Int
        var members: [Member]
    }

    enum Node {
        case object(ObjectNode)
        case scalar
    }

    struct Edit {
        var range: Range<Int>
        var text: String
    }

    private static func parseRoot(_ bytes: [UInt8]) throws -> Node? {
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
                return (.object(ObjectNode(open: open, close: index, members: members)), index + 1)
            }
            guard bytes[index] == UInt8(ascii: "\"") else { throw Failure.malformed(offset: index) }
            let keyEnd = try stringEnd(bytes, from: index)
            let keyText = String(decoding: bytes[index..<keyEnd], as: UTF8.self)
            let key = (try? JSONValue.parse(Data(keyText.utf8)))?.stringValue ?? ""
            var cursor = try skipTrivia(bytes, from: keyEnd)
            guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: ":") else { throw Failure.malformed(offset: cursor) }
            cursor = try skipTrivia(bytes, from: cursor + 1)
            let (node, valueEnd) = try parseValue(bytes, at: cursor)
            var member = Member(key: key, keyStart: index, valueStart: cursor, valueEnd: valueEnd, node: node, commaAfter: nil)
            index = try skipTrivia(bytes, from: valueEnd)
            guard index < bytes.count else { throw Failure.malformed(offset: index) }
            if bytes[index] == UInt8(ascii: ",") {
                member.commaAfter = index
                index = try skipTrivia(bytes, from: index + 1)
            } else if bytes[index] != UInt8(ascii: "}") {
                throw Failure.malformed(offset: index)
            }
            members.append(member)
        }
    }

    private static func setting(_ value: JSONValue, at path: ArraySlice<String>, in object: ObjectNode, bytes: [UInt8], edits: inout [Edit]) {
        guard let key = path.first else { return }  // the public entry refuses an empty path
        let rest = path.dropFirst()
        if let member = object.members.first(where: { $0.key == key }) {
            if rest.isEmpty {
                let indent = lineIndent(bytes, at: member.keyStart)
                edits.append(Edit(range: member.valueStart..<member.valueEnd, text: value.prettyText(baseIndent: indent)))
            } else if case .object(let child) = member.node {
                setting(value, at: rest, in: child, bytes: bytes, edits: &edits)
            } else {
                let indent = lineIndent(bytes, at: member.keyStart)
                let nested = JSONValue.nest(value, under: Array(rest))
                edits.append(Edit(range: member.valueStart..<member.valueEnd, text: nested.prettyText(baseIndent: indent)))
            }
            return
        }
        let nested = rest.isEmpty ? value : JSONValue.nest(value, under: Array(rest))
        let braceIndent = lineIndent(bytes, at: object.open)
        let memberIndent = object.members.first.map { lineIndent(bytes, at: $0.keyStart) } ?? braceIndent + "  "
        let memberText = JSONValue.quote(key) + ": " + nested.prettyText(baseIndent: memberIndent)
        guard let last = object.members.last else {
            edits.append(Edit(range: (object.open + 1)..<(object.open + 1), text: "\n" + memberIndent + memberText + "\n" + braceIndent))
            return
        }
        if let comma = last.commaAfter {
            // Keep the file's trailing-comma style and any comment that
            // follows the comma on its line.
            let insertAt = sameLineTriviaEnd(bytes, from: comma + 1)
            edits.append(Edit(range: insertAt..<insertAt, text: "\n" + memberIndent + memberText + ","))
            return
        }
        // Put the comma right after the value and the new member after any
        // same-line comment, so `"a": 1 // note` keeps its note on its line.
        let insertAt = sameLineTriviaEnd(bytes, from: last.valueEnd)
        if insertAt == last.valueEnd {
            edits.append(Edit(range: insertAt..<insertAt, text: ",\n" + memberIndent + memberText))
        } else {
            edits.append(Edit(range: last.valueEnd..<last.valueEnd, text: ","))
            edits.append(Edit(range: insertAt..<insertAt, text: "\n" + memberIndent + memberText))
        }
    }

    private static func removalEdits(memberAt index: Int, in object: ObjectNode, bytes: [UInt8]) -> [Edit] {
        let member = object.members[index]
        let start = lineStartIfBlank(bytes, before: member.keyStart)
        if let comma = member.commaAfter {
            let end = lineEndIfBlank(bytes, after: comma + 1)
            return [Edit(range: start..<end, text: "")]
        }
        let end = lineEndIfBlank(bytes, after: member.valueEnd)
        var edits = [Edit(range: start..<end, text: "")]
        if index > 0, let previousComma = object.members[index - 1].commaAfter {
            edits.append(Edit(range: previousComma..<(previousComma + 1), text: ""))
        }
        return edits
    }

    private static func apply(_ edits: [Edit], to bytes: [UInt8]) -> String {
        var result = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return String(decoding: result, as: UTF8.self)
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

    /// End of spaces and comments that follow `start` on the same line.
    private static func sameLineTriviaEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 {
                index += 1
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                return index
            } else {
                break
            }
        }
        return start
    }

    private static func lineIndent(_ bytes: [UInt8], at offset: Int) -> String {
        var lineStart = offset
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        var end = lineStart
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[lineStart..<end], as: UTF8.self)
    }

    private static func lineStartIfBlank(_ bytes: [UInt8], before offset: Int) -> Int {
        var index = offset
        while index > 0, bytes[index - 1] == 0x20 || bytes[index - 1] == 0x09 { index -= 1 }
        return index == 0 || bytes[index - 1] == 0x0A ? index : offset
    }

    private static func lineEndIfBlank(_ bytes: [UInt8], after offset: Int) -> Int {
        var index = offset
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0D { index += 1 }
        if index < bytes.count, bytes[index] == 0x0A { return index + 1 }
        return index == bytes.count ? index : offset
    }
}

extension JSONValue {
    /// `value` wrapped in one object per path component.
    static func nest(_ value: JSONValue, under path: [String]) -> JSONValue {
        path.reversed().reduce(value) { inner, key in .object([key: inner]) }
    }
}
