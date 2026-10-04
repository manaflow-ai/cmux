import CmuxNextActions
import Testing

/// `WhenClause.canOverlap` (the Keyboard Shortcuts editor's conflicts): two
/// entries on the same keys conflict unless their `when` clauses provably
/// exclude each other.
@Suite struct WhenClauseOverlapTests {
    @Test func onlyProvablyExclusiveClausesDoNotOverlap() {
        let terminal = WhenClause.equals(KeyContext.surfaceKind, .string("terminal"))
        let page = WhenClause.equals(KeyContext.surfaceKind, .string("page"))
        let notTerminal = WhenClause.notEquals(KeyContext.surfaceKind, .string("terminal"))
        #expect(WhenClause.canOverlap(nil, terminal), "no when holds everywhere")
        #expect(WhenClause.canOverlap(nil, nil))
        #expect(!WhenClause.canOverlap(terminal, page))
        #expect(!WhenClause.canOverlap(terminal, notTerminal))
        #expect(WhenClause.canOverlap(page, notTerminal))
        #expect(!WhenClause.canOverlap(.has("terminalFocused"), .not(.has("terminalFocused"))))
        #expect(!WhenClause.canOverlap(.and([terminal, .has(KeyContext.terminalCopyMode)]), notTerminal))
        #expect(WhenClause.canOverlap(.or([terminal, page]), notTerminal), "an || is not proven")
        #expect(!WhenClause.canOverlap(.constant(false), nil))
    }
}
