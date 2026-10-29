@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextWakeups
import Testing

/// The focus coordinator names what has the keyboard in the focused pane in the crash keys
/// (``CrashKeySlots/Key/paneKind``): one store per drain, from its resolved focus.
@MainActor
struct CrashKeyPaneKindTests {
    @Test func aFocusMoveNamesTheFocusedPanesKind() {
        let keys = CrashKeySlots()
        let focus = FocusCoordinator()
        focus.crashKeys = keys
        focus.send(.topology(FocusTopology(workspace: "keys-workspace", panes: [
            .init(id: "terminal-pane", tabs: [.init(id: "terminal-tab", kind: .terminal)], selected: "terminal-tab"),
            .init(id: "browser-pane", tabs: [.init(id: "browser-tab", kind: .browser)], selected: "browser-tab"),
        ])))
        focus.send(.focusPane("terminal-pane", source: .keyboard))
        #expect(keys.value(.paneKind) == CrashKeySlots.PaneKind.terminal.rawValue)
        focus.send(.focusPane("browser-pane", source: .keyboard))
        #expect(keys.value(.paneKind) == CrashKeySlots.PaneKind.browser.rawValue)
    }

    @Test func eachResolvedFocusHasItsKind() {
        #expect(CrashKeySlots.PaneKind(focus: .terminal(pane: "p", tab: "t")) == .terminal)
        #expect(CrashKeySlots.PaneKind(focus: .addressBar(pane: "p", tab: "t")) == .browser)
        #expect(CrashKeySlots.PaneKind(focus: .devTools(pane: "p", tab: "t")) == .browser)
        #expect(CrashKeySlots.PaneKind(focus: .conversation(pane: "p", tab: "t")) == .agent)
        #expect(CrashKeySlots.PaneKind(focus: .page(pane: "p", tab: "t")) == .page)
        #expect(CrashKeySlots.PaneKind(focus: .emptyPane(pane: "p")) == .empty)
        #expect(CrashKeySlots.PaneKind(focus: .sidebar) == nil, "the keyboard outside the panes names no pane")
    }
}
