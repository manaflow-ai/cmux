import CmuxNextActions
import CmuxNextFocus
import Testing
@testable import CmuxNextApp

/// The documented `shortcuts.when` terminalAlternateScreen predicate must
/// reflect the focused Ghostty terminal, so bindings such as pane focus can
/// yield to vim and tmux while their alternate screen is active.
@Suite struct TerminalAlternateScreenShortcutTests {
    private static var terminal: FocusState {
        var focus = FocusState()
        focus.resolved = .terminal(pane: "pane", tab: "tab")
        return focus
    }

    @Test func alternateScreenIsPresentOnlyForFocusedTerminal() throws {
        let active = KeyRouter.keyContext(for: Self.terminal, appContext: [], facts: KeyFacts(terminalAlternateScreen: true))
        #expect(active[KeyContext.terminalAlternateScreen] == .bool(true))
        let inactive = KeyRouter.keyContext(for: Self.terminal, appContext: [], facts: KeyFacts())
        #expect(inactive[KeyContext.terminalAlternateScreen] == nil)

        var browser = FocusState()
        browser.resolved = .browserPage(pane: "pane", tab: "tab")
        let browserContext = KeyRouter.keyContext(for: browser, appContext: [], facts: KeyFacts(terminalAlternateScreen: true))
        #expect(browserContext[KeyContext.terminalAlternateScreen] == nil)
    }

    @Test func aWhenClauseCanYieldPaneFocusInAlternateScreen() throws {
        let clause = try WhenClause.parse("!terminalAlternateScreen")
        let shell = KeyRouter.keyContext(for: Self.terminal, appContext: [], facts: KeyFacts())
        let vim = KeyRouter.keyContext(for: Self.terminal, appContext: [], facts: KeyFacts(terminalAlternateScreen: true))
        #expect(clause.evaluate(shell))
        #expect(!clause.evaluate(vim))
    }
}
