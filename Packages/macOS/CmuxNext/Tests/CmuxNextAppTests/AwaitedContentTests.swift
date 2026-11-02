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

    /// REOPEN-F4 browser case (STATUS 5871; journey reopen-browser-first-key, 3 of 5 cycles lost): a restored Chromium
    /// tab gets its page from an async start, 300-400 ms after main; meanwhile the focus names the browser page and the
    /// pane shows no browser content. A Cmd-L then took the "not a browser" branch of Focus Location Bar and opened a
    /// New Tab page, and the marker typed after it went there. The page is awaited until its content shows.
    @Test func aRestoredBrowserTabIsAwaitedUntilItsPageExists() {
        #expect(AwaitedContent.awaited(.browser, tab: "b", pane: Self.pane(selected: "b", shown: "b", kind: nil, live: false), paneInTopology: true)
                == AwaitedContent(tab: "b", kind: .browser), "a browser tab with no page yet is not awaited: a Cmd-L opens a New Tab page")
        #expect(AwaitedContent.awaited(.browser, tab: "b", pane: Self.pane(selected: "b", shown: "b", kind: .browser, live: false), paneInTopology: true) == nil)
        #expect(AwaitedContent.awaited(.browser, tab: "b", pane: Self.pane(selected: "other", shown: nil, kind: nil, live: false), paneInTopology: true) == nil)
        // Keys held for a page have no terminal lane: they run again as typed once it shows (Cmd-L then reaches its address bar).
        #expect(!AwaitedContent(tab: "b", kind: .browser).hasTerminalLane)
        #expect(AwaitedContent(tab: "t", kind: .terminal).hasTerminalLane)
    }
}
