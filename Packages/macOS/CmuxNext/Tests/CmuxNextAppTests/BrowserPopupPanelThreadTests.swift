import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// Counts the close notices an observer of the shared center saw off main.
private final class OffMainNotices: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

/// The opener-close observer is registered without a queue, so it runs on
/// the posting thread. A close notice posted off the main thread closes the
/// popups on main instead of trapping in `MainActor.assumeIsolated`
/// (plans/cmux-next/crash-elimination.md, P1b).
@MainActor
@Suite struct BrowserPopupPanelThreadTests {
    @Test func anOpenerCloseNoticePostedOffMainClosesItsPopupsOnMain() async {
        _ = NSApplication.shared
        // The shared center must never carry this off-main notice: other
        // suites in the same process leave main-actor observers of every
        // window's close on it (PointerHover's key window observer), and one
        // of those called off main traps the whole test process (signal 5).
        let leaked = OffMainNotices()
        let watch = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: nil
        ) { _ in
            if !Thread.isMainThread { leaked.add() }
        }
        defer { NotificationCenter.default.removeObserver(watch) }
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
        #expect(leaked.count == 0)
    }
}
