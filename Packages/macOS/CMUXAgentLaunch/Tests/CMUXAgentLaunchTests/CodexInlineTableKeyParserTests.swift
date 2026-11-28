import Testing
@testable import CMUXAgentLaunch

@Suite
struct CodexInlineTableKeyParserTests {
    /// Keeps escaped spellings of TOML keys equivalent to their decoded Unicode scalar values.
    @Test("Basic keys use TOML escape rules", arguments: [
        ("writable\\U0000005Froots", "writable_roots"),
        ("network\\u005faccess", "network_access"),
        ("network\\x5Faccess", "network_access"),
        ("line\\nkey", "line\nkey"),
        ("quote\\\"key", "quote\"key"),
        ("back\\\\slash", "back\\slash"),
        ("\\b\\t\\f\\r\\e", "\u{8}\t\u{C}\r\u{1B}"),
        ("face\\U0001F600", "face😀"),
        ("", "")
    ])
    func basicEscapes(fixture: (String, String)) {
        let table = "{\"\(fixture.0)\"=[]}"
        #expect(CodexInlineTableKeyParser().parse(table) == Set([fixture.1]))
    }

    /// Rejects invalid key encodings so permission recovery can preserve an unknown explicit override.
    @Test("Malformed escapes and invalid scalars stay unknown", arguments: [
        "\\U00110000", "\\uD800", "\\uDC00", "\\uD83D\\uDE00", "\\U000000GG",
        "\\u12", "\\U00005F", "\\xG0", "\\q", "\\/", "trailing\\",
        "unescaped\"quote", "line\nbreak", "control\u{7F}"
    ])
    func malformedBasicKey(key: String) {
        #expect(CodexInlineTableKeyParser().parse("{\"\(key)\"=[]}") == nil)
    }

    /// Ensures literal TOML keys retain backslashes rather than expanding Unicode escapes.
    @Test("Literal keys preserve backslashes")
    func literalKey() {
        let key = "literal\\U0000005Fkey"
        #expect(CodexInlineTableKeyParser().parse("{'\(key)'=[]}") == Set([key]))
    }
}
