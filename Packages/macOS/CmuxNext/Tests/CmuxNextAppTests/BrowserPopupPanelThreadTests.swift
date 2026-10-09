import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import Testing

/// The opener-close observer is registered without a queue, so it runs on
/// the posting thread. A close notice posted off the main thread closes the
/// popups on main instead of trapping in `MainActor.assumeIsolated`
/// (plans/cmux-next/crash-elimination.md, P1b).
@MainActor
@Suite struct BrowserPopupPanelThreadTests {
    @Test func anOpenerCloseNoticePostedOffMainClosesItsPopupsOnMain() async {
        _ = NSApplication.shared
        let panels = BrowserPopupPanels()
        panels.ordersPanelsIn = false
        let parent = NSWindow(contentRect: CGRect(x: 200, y: 100, width: 1000, height: 700), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://accounts.example.com/auth")))
        panels.open(page, request: BrowserPopupRequest(), over: parent, openerKey: "tab-1")
        #expect(panels.owns(page))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parent)
                DispatchQueue.main.async { done.resume() }
            }
        }
        #expect(!panels.owns(page))
        #expect(page.isClosed)
    }
}
