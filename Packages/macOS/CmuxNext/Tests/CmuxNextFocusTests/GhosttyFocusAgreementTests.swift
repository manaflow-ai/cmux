import CmuxNextFocus
import Testing

/// `debug.focus`'s Ghostty check, moved into CmuxNextFocus (`FocusState.Resolved.ghosttyMismatch`): the same texts as
/// before the move, for each case.
struct GhosttyFocusAgreementTests {
    @Test func theKeyWindowsTerminalMustBeTheOnlyGhosttyFocusOfItsTabs() {
        let terminal = FocusState.Resolved.terminal(pane: "p", tab: "t")
        #expect(terminal.ghosttyMismatch(focused: ["t", "elsewhere"], ownTabs: ["t", "u"], isKey: true) == nil)
        #expect(terminal.ghosttyMismatch(focused: ["u"], ownTabs: ["t", "u"], isKey: true) == "ghostty focused [\"u\"] != [t]")
        #expect(terminal.ghosttyMismatch(focused: [], ownTabs: ["t"], isKey: true) == "ghostty focused [] != [t]")
    }

    @Test func noOtherFocusMayLeaveAGhosttyFocusInItsWindow() {
        #expect(FocusState.Resolved.sidebar.ghosttyMismatch(focused: ["elsewhere"], ownTabs: ["t"], isKey: true) == nil)
        #expect(FocusState.Resolved.sidebar.ghosttyMismatch(focused: ["t"], ownTabs: ["t"], isKey: true)
            == "ghostty focused [\"t\"] while model is sidebar")
        #expect(FocusState.Resolved.terminal(pane: "p", tab: "t").ghosttyMismatch(focused: ["t"], ownTabs: ["t"], isKey: false)
            == "ghostty focused [\"t\"] while model is terminal (window not key)")
    }
}
