import CmuxNextActions
import Testing

/// A keybindings.json `when` nests `!` and `(` at most ``WhenClauseParser/maxDepth`` (200) levels: a deeper
/// clause is a parse error for its entry, never a recursion that runs the app out of stack
/// (Chromium bounds JSON the same way, base/json/json_common.h `kAbsoluteMaxDepth`).
struct WhenClauseDepthTests {
    nonisolated static let limit = 200

    static func parens(_ depth: Int) -> String {
        String(repeating: "(", count: depth) + "editorFocus" + String(repeating: ")", count: depth)
    }

    static func nots(_ depth: Int) -> String {
        String(repeating: "!", count: depth) + "editorFocus"
    }

    /// `!(` pairs: each pair is two levels.
    static func mixed(_ pairs: Int) -> String {
        String(repeating: "!(", count: pairs) + "a && b" + String(repeating: ")", count: pairs)
    }

    @Test(arguments: [1, limit - 1, limit])
    func nestingUpToTheLimitParses(depth: Int) throws {
        #expect(try WhenClause.parse(Self.parens(depth)) == .has("editorFocus"))
        var expected = WhenClause.has("editorFocus")
        for _ in 0..<depth { expected = .not(expected) }
        #expect(try WhenClause.parse(Self.nots(depth)) == expected)
        let mixed = try WhenClause.parse(Self.mixed(depth / 2))
        #expect(try WhenClause.parse(mixed.text) == mixed, "a parsed clause's text reads back")
    }

    @Test(arguments: [limit + 1, 512, 100_000])
    func nestingPastTheLimitIsAParseError(depth: Int) {
        for text in [Self.parens(depth), Self.nots(depth), Self.mixed((depth + 1) / 2), String(repeating: "(", count: depth)] {
            let result = Result<WhenClause, WhenClauseParseError> { () throws(WhenClauseParseError) in try WhenClause.parse(text) }
            guard case .failure(let error) = result else {
                Issue.record("depth \(depth) parsed")
                continue
            }
            #expect(error.message == "nested too deep")
        }
    }

    /// Levels that close free their depth: siblings each nested to the limit parse.
    @Test func closedLevelsDoNotCount() throws {
        let sibling = Self.parens(Self.limit)
        let clause = try WhenClause.parse(Array(repeating: sibling, count: 50).joined(separator: " && "))
        #expect(clause == .and(Array(repeating: .has("editorFocus"), count: 50)))
    }
}
