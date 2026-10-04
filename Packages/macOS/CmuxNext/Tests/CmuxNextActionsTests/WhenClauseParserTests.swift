import CmuxNextActions
import Testing

/// The `when` grammar (spec K4): VS Code's operators, `&&` before `||`,
/// parentheses, quoted and bare values, `/regex/i`, `in` and `not in`; a
/// parse error names its offset.
@Suite struct WhenClauseParserTests {
    static let page = KeyContext([
        KeyContext.surfaceKind: .string("page"), KeyContext.focus: .string("omnibar"), "page.host": .string("GitHub.com"),
        "pinnedHosts": .strings(["GitHub.com"]), "columns.count": .number(2), "terminalFocused": .bool(false),
    ])

    @Test func operatorsAndPrecedence() throws {
        let cases: [(String, WhenClause)] = [
            ("surfaceKind == page", .equals("surfaceKind", .string("page"))),
            ("surfaceKind != 'terminal'", .notEquals("surfaceKind", .string("terminal"))),
            ("!terminalFocused", .not(.has("terminalFocused"))),
            ("a && b || c", .or([.and([.has("a"), .has("b")]), .has("c")])),
            ("a && (b || c)", .and([.has("a"), .or([.has("b"), .has("c")])])),
            ("columns.count == 2", .equals("columns.count", .number(2))),
            ("page.host =~ /^github\\./i", .matches("page.host", pattern: "(?i)^github\\.")),
            ("page.host in pinnedHosts", .isIn("page.host", listKey: "pinnedHosts")),
            ("page.host not in pinnedHosts", .not(.isIn("page.host", listKey: "pinnedHosts"))),
            ("true", .constant(true)),
            ("inbox", .has("inbox")),
            ("app.notes.editing == \"yes\"", .equals("app.notes.editing", .string("yes"))),
        ]
        for (text, expected) in cases {
            #expect(try WhenClause.parse(text) == expected, "\(text)")
        }
    }

    @Test func parsedClausesEvaluate() throws {
        #expect(try WhenClause.parse("surfaceKind == page && focus == omnibar").evaluate(Self.page))
        #expect(try WhenClause.parse("surfaceKind != terminal && !terminalFocused").evaluate(Self.page))
        #expect(try WhenClause.parse("page.host =~ /^github\\.com$/i").evaluate(Self.page))
        #expect(try !WhenClause.parse("page.host =~ /^github\\.com$/").evaluate(Self.page))
        #expect(try WhenClause.parse("page.host in pinnedHosts && columns.count == 2").evaluate(Self.page))
        #expect(try !WhenClause.parse("terminalFocused || surfaceKind == agent").evaluate(Self.page))
    }

    @Test func errorsNameTheirOffset() {
        for (text, offset) in [("surfaceKind ==", 14), ("(a && b", 7), ("a &&", 4), ("a == 'x", 7), ("a b", 2), ("x =~ y", 5)] {
            #expect(throws: WhenClauseParseError.self, "\(text)") { try WhenClause.parse(text) }
            do {
                _ = try WhenClause.parse(text)
            } catch {
                #expect(error.offset == offset, "\(text): \(error.message)")
            }
        }
    }
}
