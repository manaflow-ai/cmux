@testable import CmuxNextFocusUI
import Testing

/// REOPEN-F4: the focused content a key typed now would miss (``AwaitedContent``). The window's key hold waits for it,
/// so the first keys after a reopen reach the restored focused content instead of no view.
@MainActor @Suite struct AwaitedContentTests {
    private static func pane(selected: String?, shown: String?, kind: AwaitedContent.Kind?, live: Bool = true) -> AwaitedContent.Pane {
        AwaitedContent.Pane(selectedTab: selected, shownTab: shown, shownKind: kind, selectedIsLiveTerminal: live)
    }

    /// A restored terminal whose surface is not shown yet is awaited; once it shows, nothing is (the common case of
    /// every key-down).
    @Test func aFocusedTerminalIsAwaitedUntilItsSurfaceShows() {
        #expect(AwaitedContent.awaited(.terminal, tab: "t", pane: Self.pane(selected: "t", shown: nil, kind: nil), paneInTopology: true)
                == AwaitedContent(tab: "t", kind: .terminal))
        #expect(AwaitedContent.awaited(.terminal, tab: "t", pane: Self.pane(selected: "t", shown: "t", kind: .terminal), paneInTopology: true) == nil)
        // The pane has no controller yet (the window comes forward before it mounts): awaited while the topology has it.
        #expect(AwaitedContent.awaited(.terminal, tab: "t", pane: nil, paneInTopology: true) == AwaitedContent(tab: "t", kind: .terminal))
        #expect(AwaitedContent.awaited(.terminal, tab: "t", pane: nil, paneInTopology: false) == nil)
    }

    /// A dead terminal, or a pane that selects another tab, holds nothing: no key would be lost for it.
    @Test func aDeadOrUnselectedTerminalIsNotAwaited() {
        #expect(AwaitedContent.awaited(.terminal, tab: "t", pane: Self.pane(selected: "t", shown: nil, kind: nil, live: false), paneInTopology: true) == nil)
        #expect(AwaitedContent.awaited(.terminal, tab: "t", pane: Self.pane(selected: "other", shown: nil, kind: nil), paneInTopology: true) == nil)
    }
}
