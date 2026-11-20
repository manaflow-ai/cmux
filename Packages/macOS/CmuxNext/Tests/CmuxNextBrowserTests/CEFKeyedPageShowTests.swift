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
}
