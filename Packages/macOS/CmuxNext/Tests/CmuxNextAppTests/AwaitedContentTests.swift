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

    /// reopen-browser-plain-keys cycle B (STATUS 7493): after a reopen the restored Chromium tab is shown in its pane
    /// (its browser content exists) 200 ms before Chromium creates its browser; plain keys typed then went to the cmux
    /// window and were lost (the first page attach came 257.5 ms after the first key). The page is awaited until its
    /// browser exists.
    @Test func aShownBrowserTabIsAwaitedUntilItsPageIsReady() {
        let shownNotReady = AwaitedContent.Pane(selectedTab: "b", shownTab: "b", shownKind: .browser, selectedIsLiveTerminal: false, shownPageReady: false)
        #expect(AwaitedContent.awaited(.browser, tab: "b", pane: shownNotReady, paneInTopology: true) == AwaitedContent(tab: "b", kind: .browser),
                "a shown browser tab whose page is not created yet is not awaited: plain keys typed then are lost")
        let ready = AwaitedContent.Pane(selectedTab: "b", shownTab: "b", shownKind: .browser, selectedIsLiveTerminal: false, shownPageReady: true)
        #expect(AwaitedContent.awaited(.browser, tab: "b", pane: ready, paneInTopology: true) == nil)
    }

    /// Review of #32030: a cold Chromium tab (Ctrl-Tab onto a tab never shown) also has no page for 100-400 ms. While
    /// its hold has no keys, an app shortcut that does not need the page (Ctrl-Tab, Cmd-T, Cmd-1) acts at once; a page
    /// action (Cmd-L) and every plain key wait for the page; once a key is held, every later one waits behind it.
    @Test func aPageHoldLetsAppShortcutsPassWhileEmptyButKeepsPageActions() {
        #expect(!AwaitedContent.pageHoldKeeps(isChord: true, holdIsEmpty: true, command: "nextTab"), "Ctrl-Tab waited for a cold tab's page")
        #expect(AwaitedContent.pageHoldKeeps(isChord: true, holdIsEmpty: true, command: "focusLocation"), "Cmd-L ran before the page existed")
        #expect(AwaitedContent.pageHoldKeeps(isChord: true, holdIsEmpty: true, command: nil), "a chord the page takes (no app binding) ran into no page")
        #expect(AwaitedContent.pageHoldKeeps(isChord: false, holdIsEmpty: true, command: nil))
        #expect(AwaitedContent.pageHoldKeeps(isChord: true, holdIsEmpty: false, command: "nextTab"), "a shortcut passed a held key")
    }

    /// A page hold that ended at its bound excludes that tab from new page holds (its page may never come), until the
    /// page arrives (review of #32030): a later cold show of it holds again.
    @Test func aTabExcludedAfterItsBoundIsHeldAgainOnceItsPageArrived() {
        var log = CreationHoldLog()
        _ = log.end(in: 1, forced: .limitReached, pageTab: "b")
        #expect(log.pageExpired.contains("b"))
        log.pageArrived("b")
        #expect(!log.pageExpired.contains("b"))
        _ = log.end(in: 1, forced: .focusLeft, pageTab: "c")
        #expect(!log.pageExpired.contains("c"), "a hold the focus left is not a page that never comes")
    }

    /// Review of #32633: a page hold now waits for the restored document, which can take seconds on a slow page. Cmd-L
    /// needs only the page's address bar: with no key held before it, it goes on once Chromium created the page (as
    /// before #32633). A plain key, a chord the page takes, and Cmd-L behind held keys still wait.
    @Test func aPageActionPassesAnEmptyPageHoldOnceThePageExists() {
        #expect(!AwaitedContent.pageHoldKeeps(isChord: true, holdIsEmpty: true, command: "focusLocation", pageCreated: true),
                "Cmd-L waited for the restored document although the page existed")
        #expect(AwaitedContent.pageHoldKeeps(isChord: true, holdIsEmpty: true, command: "focusLocation", pageCreated: false))
        #expect(AwaitedContent.pageHoldKeeps(isChord: true, holdIsEmpty: false, command: "focusLocation", pageCreated: true), "Cmd-L passed held keys")
        #expect(AwaitedContent.pageHoldKeeps(isChord: true, holdIsEmpty: true, command: nil, pageCreated: true), "a page's chord ran into no document")
        #expect(AwaitedContent.pageHoldKeeps(isChord: false, holdIsEmpty: true, command: nil, pageCreated: true))
    }
}
