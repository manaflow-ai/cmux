import CmuxNextActions
import Testing

/// `WhenClause.text` (keybinding.list, the editor's When column): the text
/// parses back to the same clause.
@Suite struct WhenClauseTextTests {
    @Test func textParsesBackToTheSameClause() throws {
        let clauses: [WhenClause] = [
            .constant(true),
            .has("terminalFocused"),
            .notEquals(KeyContext.surfaceKind, .string("terminal")),
            .and([.equals(KeyContext.surfaceKind, .string("terminal")), .has(KeyContext.terminalCopyMode)]),
            .or([.has("a"), .and([.has("b"), .not(.has("c"))])]),
            .and([.or([.has("a"), .has("b")]), .has("c")]),
            .not(.and([.has("a"), .has("b")])),
            .not(.isIn("page.host", listKey: "pinned")),
            .isIn("page.host", listKey: "pinned"),
            .equals("columns.count", .number(2)),
            .equals("title", .string("two words")),
            .equals("flag", .string("true")),
            .equals("version", .string("12")),
            .matches("page.host", pattern: "(?i)^git.*\\.com$"),
        ]
        for clause in clauses {
            #expect(try WhenClause.parse(clause.text) == clause, "\(clause.text)")
        }
        #expect(WhenClause.and([.has("a"), .not(.has("b"))]).text == "a && !b")
        #expect(WhenClause.notEquals(KeyContext.surfaceKind, .string("terminal")).text == "surfaceKind != terminal")
    }
}
