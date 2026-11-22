/// Parses a `when` clause (plans/cmux-next/keybindings.md section 4, spec
/// K4): `!`, `&&`, `||`, `==`, `!=`, `=~`, `in`, `not in`, parentheses,
/// `true`, `false`, context keys and values (quoted, bare or numeric;
/// `=~` takes `/regex/` with an optional `i` flag). `&&` binds tighter than
/// `||`. A parse error disables only the entry that holds the clause.
public nonisolated struct WhenClauseParseError: Error, Equatable, Sendable {
    /// What is wrong (English; the editor shows a localized summary).
    public var message: String
    /// UTF-8 offset of the problem in the clause text.
    public var offset: Int
}

extension WhenClause {
    /// Parses `text`. Throws ``WhenClauseParseError``.
    public static func parse(_ text: String) throws(WhenClauseParseError) -> WhenClause {
        var parser = WhenClauseParser(Array(text.utf8))
        let clause = try parser.parseOr()
        parser.skipSpace()
        guard parser.isAtEnd else { throw parser.error("unexpected text") }
        return clause
    }
}

nonisolated struct WhenClauseParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { index >= bytes.count }

    func error(_ message: String) -> WhenClauseParseError {
        WhenClauseParseError(message: message, offset: index)
    }

    mutating func skipSpace() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
    }

    private mutating func take(_ token: String) -> Bool {
        skipSpace()
        let utf8 = Array(token.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else { return false }
        index += utf8.count
        return true
    }

    /// A keyword followed by a non-word byte (`in` must not eat `inbox`).
    private mutating func takeWord(_ word: String) -> Bool {
        let start = index
        guard take(word) else { return false }
        if index < bytes.count, Self.isWordByte(bytes[index]) {
            index = start
            return false
        }
        return true
    }

    mutating func parseOr() throws(WhenClauseParseError) -> WhenClause {
        var clauses = [try parseAnd()]
        while take("||") { clauses.append(try parseAnd()) }
        return clauses.count == 1 ? clauses[0] : .or(clauses)
    }

    private mutating func parseAnd() throws(WhenClauseParseError) -> WhenClause {
        var clauses = [try parseUnary()]
        while take("&&") { clauses.append(try parseUnary()) }
        return clauses.count == 1 ? clauses[0] : .and(clauses)
    }

    private mutating func parseUnary() throws(WhenClauseParseError) -> WhenClause {
        skipSpace()
        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "!"), bytes[index + 1] != UInt8(ascii: "=") {
            index += 1
            return .not(try parseUnary())
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws(WhenClauseParseError) -> WhenClause {
        if take("(") {
            let inner = try parseOr()
            guard take(")") else { throw error("expected )") }
            return inner
        }
        if takeWord("true") { return .constant(true) }
        if takeWord("false") { return .constant(false) }
        let key = try parseKey()
        if take("==") { return .equals(key, try parseValue()) }
        if take("!=") { return .notEquals(key, try parseValue()) }
        if take("=~") { return .matches(key, pattern: try parseRegex()) }
        let beforeNot = index
        if takeWord("not") {
            guard takeWord("in") else {
                index = beforeNot
                return .has(key)
            }
            return .not(.isIn(key, listKey: try parseKey()))
        }
        if takeWord("in") { return .isIn(key, listKey: try parseKey()) }
        return .has(key)
    }

    private mutating func parseKey() throws(WhenClauseParseError) -> String {
        skipSpace()
        let start = index
        while index < bytes.count, Self.isWordByte(bytes[index]) { index += 1 }
        guard index > start else { throw error("expected a context key") }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func parseValue() throws(WhenClauseParseError) -> KeyContextValue {
        skipSpace()
        guard index < bytes.count else { throw error("expected a value") }
        let quote = bytes[index]
        if quote == UInt8(ascii: "'") || quote == UInt8(ascii: "\"") {
            index += 1
            let start = index
            while index < bytes.count, bytes[index] != quote { index += 1 }
            guard index < bytes.count else { throw error("unterminated string") }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return .string(text)
        }
        let start = index
        while index < bytes.count, Self.isValueByte(bytes[index]) { index += 1 }
        guard index > start else { throw error("expected a value") }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if let number = Double(text) { return .number(number) }
        return .string(text)
    }

    private mutating func parseRegex() throws(WhenClauseParseError) -> String {
        skipSpace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "/") else { throw error("expected /regex/") }
        index += 1
        var pattern: [UInt8] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: "/") {
            if bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count {
                pattern.append(bytes[index])
                index += 1
            }
            pattern.append(bytes[index])
            index += 1
        }
        guard index < bytes.count else { throw error("unterminated /regex/") }
        index += 1
        var flags = ""
        while index < bytes.count, Self.isWordByte(bytes[index]) {
            flags.append(Character(UnicodeScalar(bytes[index])))
            index += 1
        }
        let text = String(decoding: pattern, as: UTF8.self)
        return flags.contains("i") ? "(?i)" + text : text
    }

    /// Context key bytes: letters, digits, `.`, `_`, `-`, `:`.
    static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":")
    }

    /// Bare value bytes: key bytes plus `/`, `@`, `+`, `#`.
    static func isValueByte(_ byte: UInt8) -> Bool {
        isWordByte(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "@") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "#")
    }
}
