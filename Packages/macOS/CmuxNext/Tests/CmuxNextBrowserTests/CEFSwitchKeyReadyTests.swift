import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// The keys right after a switch between two workspaces that each show a page. It is a part of
/// ``CEFDeferredFocusTests`` (the same serialized suite and the same stand-in shim) in its own file.
extension CEFDeferredFocusTests {
    /// A switch between two workspaces that each show a page moves the key window twice (2026-11-13, a read of a
    /// sample of 10 such switches): in the switch's turn the window of the page that left is ordered out and AppKit
    /// gives the keys to the cmux window; the page that shows takes them only after its first frame. A key typed
    /// between the two must go into the page that shows. The app holds a key while the shown page is not ready for
    /// keys (`AwaitedContent`) and sends the held keys to the key window when the page reports ready
    /// (``CEFTab/onReadyForKeys``). So, from the turn of the switch on, the page that shows is not ready until its
    /// grant; it reports ready only after it has the focus and its window has the keys; and the page that left gets
    /// neither again.
    @Test func aPageShownByAWorkspaceSwitchIsReadyForKeysOnlyOnceItsWindowHasThem() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let content = try #require(window.contentView)
        // Two workspaces with one loaded page each: the first one shows, the second one is hidden.
        let (leaving, _) = try createdTab(runtime, browser: 41)
        let (showing, _) = try createdTab(runtime, browser: 42)
        let workspaces = [leaving, showing].map { tab in
            let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            workspace.addSubview(tab.contentView)
            return workspace
        }
        for workspace in workspaces { content.addSubview(workspace) }
        workspaces[1].isHidden = true
        Self.load(runtime, 41, "https://example.com/first")
        Self.load(runtime, 42, "https://example.com/second")
        Self.endTurn()
        try #require(leaving.pageReady && showing.pageReady, "a loaded page with no focus ask is ready: the test proves nothing")
        let leavingPage = pageWindow(over: leaving, in: window)
        defer { leavingPage.closeAfterTest() }
        let keys = KeyRecorder(key: window)
        leaving.keyWindows = keys.seam
        showing.keyWindows = keys.seam
        leaving.setFocused(true)
        try #require(FocusSpyShim.granted == [41] && keys.key === leavingPage, "the first page did not take the keys: \(FocusSpyShim.granted)")
        FocusSpyShim.granted = []
        let log = CallLog()
        FocusSpyShim.onGrant = { log.items.append("grant") }
        defer { FocusSpyShim.onGrant = nil }
        showing.onReadyForKeys = { log.items.append("ready") }
        leaving.onReadyForKeys = { log.items.append("ready (the page that left)") }

        // The switch's turn. The first workspace hides and its page loses the focus; the fork orders that page's
        // window out, and AppKit gives the keys to the cmux window. The second workspace shows, its page window
        // comes in its place, and the focus applier asks for its page.
        workspaces[0].isHidden = true
        leaving.setFocused(false)
        window.removeChildWindow(leavingPage)
        keys.key = window
        workspaces[1].isHidden = false
        let showingPage = pageWindow(over: showing, in: window)
        defer { showingPage.closeAfterTest() }
        showing.setFocused(true)

        // A key typed now: no page has the keys, and the page that shows says so, so the app holds the key for it.
        #expect(!showing.pageReady, "the page that shows counts as ready for keys before it has them: a key typed now is not held and reaches no page")
        #expect(FocusSpyShim.granted.isEmpty, "a page took the focus in the turn of the switch: \(FocusSpyShim.granted)")
        #expect(keys.key === window && keys.made.count == 1, "the keys moved in the turn of the switch")
        #expect(log.items.isEmpty, "a page reported ready in the turn of the switch: \(log.items)")

        // The turn ends (the frame of the switch): the page that shows takes the focus and the keys, then reports.
        Self.endTurn()
        #expect(FocusSpyShim.granted == [42], "the focus after the switch went to \(FocusSpyShim.granted) (want the page that shows, once)")
        #expect(keys.key === showingPage, "the page that shows has the focus but its window has no keys: the held keys reach no page")
        #expect(keys.made.count == 2, "the switch made \(keys.made.count - 1) key changes by a grant (want 1)")
        #expect(showing.pageReady)
        #expect(log.items == ["grant", "ready"], "the page must report ready for keys only after its grant, and once: \(log.items)")
    }

    /// The same switch with layer-hosted pages, as each page of the app is (the stand-in shim reports fork API 0, so
    /// the pages of the test above are not hosted and take no first-frame hold). A hosted page that a switch shows
    /// stays out of the window for its first frame (`CEFLayerHosting.pageAppeared`): the commit of the switch's turn
    /// tries the grant, the hold keeps the focus ask, and the hold's end grants it after the frame, when the fork
    /// brought the page's window back. A key typed in that time must stay held. So the page is not ready for keys
    /// and reports nothing from the turn of the switch to the end of the hold, and at the time of its one report its
    /// window has the keys.
    @Test func aHostedPageShownByAWorkspaceSwitchReportsReadyForKeysOnlyAfterItsFirstFrame() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let content = try #require(window.contentView)
        let (leaving, leavingHost) = try createdTab(runtime, browser: 43)
        let (showing, showingHost) = try createdTab(runtime, browser: 44)
        let workspaces = [leaving, showing].map { tab in
            let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            workspace.addSubview(tab.contentView)
            return workspace
        }
        for workspace in workspaces { content.addSubview(workspace) }
        Self.load(runtime, 43, "https://example.com/first")
        Self.load(runtime, 44, "https://example.com/second")
        Self.endTurn()
        let leavingPage = pageWindow(over: leaving, in: window)
        defer { leavingPage.closeAfterTest() }
        // The window of the page that shows. Both pages fill the same area. A hosted page's window is out of the
        // cmux window while the page is detached. The fork's stand-in below puts it in one run-loop pass after the
        // attach call, as the fork does (its order-in observer runs in the pass after the attach, and the hold's end
        // waits for that pass's commit): a grant at the attach call finds no window to make key.
        let showingPage = NSWindow(contentRect: leavingPage.frame, styleMask: .borderless, backing: .buffered, defer: true)
        showingPage.setFrame(leavingPage.frame, display: false)
        defer { showingPage.closeAfterTest() }
        let log = CallLog()
        _ = try hostedPage(of: leavingHost, browser: 43) { _ in }
        let hosting = try hostedPage(of: showingHost, browser: 44) { detached in
            log.items.append(detached ? "detach" : "attach")
            if !detached { CEFLayerHosting.atEndOfTurn { window.addChildWindow(showingPage, ordered: .above) } }
        }
        // The second workspace hides: the first one shows.
        workspaces[1].isHidden = true
        Self.endTurn()
        try #require(leaving.pageReady && showing.pageReady, "a loaded page with no focus ask is ready: the test proves nothing")
        try #require(log.items.isEmpty && !hosting.holdsFirstFrame(), "the hidden page has a hold before the switch: \(log.items)")
        let keys = KeyRecorder(key: window)
        leaving.keyWindows = keys.seam
        showing.keyWindows = keys.seam
        leaving.setFocused(true)
        try #require(FocusSpyShim.granted == [43] && keys.key === leavingPage, "the first page did not take the keys: \(FocusSpyShim.granted)")
        FocusSpyShim.granted = []
        FocusSpyShim.onGrant = { log.items.append("grant") }
        defer { FocusSpyShim.onGrant = nil }
        // The report reads the key window at its own time: a report before the page's window has the keys says so.
        showing.onReadyForKeys = { log.items.append(keys.key === showingPage ? "ready with the keys" : "ready with no keys") }
        leaving.onReadyForKeys = { log.items.append("ready (the page that left)") }

        // The switch's turn, as in the test above. The page that shows is detached for its first frame.
        workspaces[0].isHidden = true
        leaving.setFocused(false)
        window.removeChildWindow(leavingPage)
        keys.key = window
        workspaces[1].isHidden = false
        showing.setFocused(true)
        try #require(hosting.holdsFirstFrame() && log.items == ["detach"], "the page that shows took no first-frame hold: the test proves nothing (\(log.items))")
        #expect(!showing.pageReady, "a hosted page counts as ready for keys in the turn of the switch: a key typed now is not held")

        // The turn ends and its frame did not come yet (a test window is never on screen: its display link stays
        // still). The commit's grant found the hold, so the ask is kept: still no focus, no keys and no report.
        Self.endTurn()
        try #require(!showing.appearedThisTurn, "the commit of the switch's turn did not run its grant try: the asserts below prove nothing")
        #expect(hosting.holdsFirstFrame(), "the first-frame hold ended with no frame")
        #expect(!showing.pageReady, "a hosted page counts as ready for keys while its first-frame hold keeps its focus ask: a key typed now is not held and reaches no page")
        #expect(FocusSpyShim.granted.isEmpty, "a page took the focus before the frame of the switch: \(FocusSpyShim.granted)")
        #expect(keys.key === window && keys.made.count == 1, "the keys moved before the frame of the switch")
        #expect(log.items == ["detach"], "a page reported ready, or came back, while its first-frame hold kept its focus ask: \(log.items)")

        // The window's display frames, by hand (see `aHostedPageShownInThisTurnOrdersItsWindowInOnlyAfterTheCommit`):
        // the page's window comes back, the page takes the focus and the keys, and only then it reports, one time.
        let frames = FrameScheduler.forWindow(window)
        let deadline = Date().addingTimeInterval(2)
        while FocusSpyShim.granted.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            frames.frameDidFire()
        }
        Self.endTurn()
        #expect(FocusSpyShim.granted == [44], "the focus after the switch went to \(FocusSpyShim.granted) (want the page that shows, once)")
        #expect(keys.key === showingPage && keys.made.count == 2, "the page that shows has the focus but its window has no keys, or the keys moved more than once")
        #expect(showing.pageReady && !hosting.isDetached)
        #expect(log.items == ["detach", "attach", "grant", "ready with the keys"],
                "a hosted page must report ready for keys one time, after its grant, with the keys in its window: \(log.items)")
    }

    /// Makes the page of `host` layer-hosted through a stand-in for the fork's calls, as the hosted tests of
    /// `CEFDeferredFocusTests.swift` do. `detached` gets each detach (`true`) and each attach (`false`) of its window.
    private func hostedPage(of host: CEFPaneHost, browser: Int32, detached: @escaping (Bool) -> Void) throws -> CEFLayerHosting {
        let fork = CEFLayerHosting.Fork(setLayerHosting: { _, on in on ? 7 : 0 }, setResizeSync: { _, _ in true },
                                        setDetachedHosting: { _, on in detached(on); return true })
        let hosting = host.hostView.layerHosting
        hosting.holdsFocus = { false }
        hosting.pageWindowCreated(browser: browser, fork: fork)
        let deadline = Date().addingTimeInterval(2)
        while hosting.page == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try #require(hosting.page != nil, "the stand-in fork did not host the page: the test proves nothing")
        return hosting
    }
}
