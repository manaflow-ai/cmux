import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// A page that has the keys and is shown again. It is a part of ``CEFDeferredFocusTests`` (the same serialized suite
/// and the same stand-in shim) in its own file.
extension CEFDeferredFocusTests {
    /// "i did cmd n and started typing and it didnt have focus" (Lawrence, 2026-11-19). Cmd-N's New Tab page takes the
    /// focus and its window takes the keys, then the new workspace is put in the window and the page's view appears a
    /// second time, 100 to 270 ms after the key (cmdn-typing bench, cmux21, 2026-11-20: 7 of 30 runs lost 28 keys).
    /// That show took a first-frame hold (`CEFLayerHosting.pageAppeared`): the fork detached the page that had the keys,
    /// AppKit gave them to the cmux window with no responder, the page blurred, and every key typed until the hold's
    /// grant was lost. A page whose window has the keys from its grant is in the window, whatever the host's place
    /// says at that show: it takes no hold, and its window keeps the keys.
    @Test func aHostedPageWithTheKeysShownAgainKeepsItsWindowAndTheKeys() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let content = try #require(window.contentView)
        let (tab, host) = try createdTab(runtime, browser: 47)
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        workspace.addSubview(tab.contentView)
        content.addSubview(workspace)
        Self.load(runtime, 47, "https://example.com/new-tab")
        Self.endTurn()
        let page = pageWindow(over: tab, in: window)
        defer { page.closeAfterTest() }
        let log = CallLog()
        let fork = CEFLayerHosting.Fork(setLayerHosting: { _, on in on ? 7 : 0 }, setResizeSync: { _, _ in true },
                                        setDetachedHosting: { _, on in log.items.append(on ? "detach" : "attach"); return true })
        let hosting = host.hostView.layerHosting
        hosting.holdsFocus = { false }
        hosting.pageWindowCreated(browser: 47, fork: fork)
        let hosted = Date().addingTimeInterval(2)
        while hosting.page == nil, Date() < hosted { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try #require(hosting.page != nil, "the stand-in fork did not host the page: the test proves nothing")
        let keys = KeyRecorder(key: window)
        tab.keyWindows = keys.seam
        tab.setFocused(true)
        Self.endTurn()
        try #require(FocusSpyShim.granted == [47] && keys.key === page && log.items.isEmpty && !hosting.holdsFirstFrame(),
                     "the page did not take the focus and the keys: the test proves nothing (\(FocusSpyShim.granted), \(log.items))")
        FocusSpyShim.granted = []
        FocusSpyShim.onGrant = { log.items.append("grant") }
        defer { FocusSpyShim.onGrant = nil }

        // The new workspace is put in the window: in one turn the page's view leaves the window and comes back, at a
        // place its window is not at yet (the layout moves the window there after).
        workspace.removeFromSuperview()
        workspace.setFrameOrigin(NSPoint(x: 0, y: 20))
        content.addSubview(workspace)
        #expect(!hosting.holdsFirstFrame() && log.items.isEmpty,
                "the page with the keys took a first-frame hold when it showed again: its window goes out and the keys typed now are lost (\(log.items))")
        #expect(keys.key === page && keys.made.count == 1, "the keys left the page when it showed again")

        // Its frames come and go: the page keeps the keys, with no second grant and no key change.
        let frames = FrameScheduler.forWindow(window)
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            frames.frameDidFire()
        }
        Self.endTurn()
        #expect(log.items.isEmpty && !hosting.isDetached, "the page with the keys was detached or granted again: \(log.items)")
        #expect(keys.key === page && keys.made.count == 1, "the keys moved after the page showed again: \(keys.made.count) key changes")
    }

    /// The same Cmd-N, at the drain of its held keys (cmdn-typing bench, cmux21, 2026-11-20: 3 of 30 runs lost 9 keys
    /// after the fix above). The New Tab page reported its field ready, and the hold asked again for the focus of the
    /// page that already had it, with its window key. Each ask is one `SetFocus(true)` in Chromium, and the keys
    /// typed in the next 20 to 50 ms reached no element of the page (no keydown, no input). A page that has the focus
    /// and whose window has the keys from that grant needs no grant: the ask moves nothing.
    @Test func aFocusAskForAPageThatHasTheFocusAndTheKeysGrantsNothing() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let (tab, _) = try createdTab(runtime, browser: 48)
        try #require(window.contentView).addSubview(tab.contentView)
        Self.load(runtime, 48, "https://example.com/new-tab")
        Self.endTurn()
        let page = pageWindow(over: tab, in: window)
        defer { page.closeAfterTest() }
        let keys = KeyRecorder(key: window)
        tab.keyWindows = keys.seam
        tab.setFocused(true)
        try #require(FocusSpyShim.granted == [48] && keys.key === page, "the page did not take the focus and the keys: the test proves nothing")

        // The field reports ready: the hold asks for the page's focus again.
        tab.setFocused(true)
        #expect(FocusSpyShim.granted == [48], "a page with the focus and the keys was granted the focus again: \(FocusSpyShim.granted)")
        #expect(keys.key === page && keys.made.count == 1)

        // After a blur, or with the keys in another window, an ask grants again.
        tab.setFocused(false)
        tab.setFocused(true)
        #expect(FocusSpyShim.granted == [48, 48], "a page that lost the focus was not granted it again: \(FocusSpyShim.granted)")
        keys.key = window
        tab.setFocused(true)
        #expect(FocusSpyShim.granted == [48, 48, 48], "a page whose window lost the keys was not granted the focus again: \(FocusSpyShim.granted)")
        #expect(keys.key === page)
    }
}
