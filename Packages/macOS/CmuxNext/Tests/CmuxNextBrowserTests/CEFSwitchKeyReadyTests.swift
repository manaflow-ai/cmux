import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
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
}
