import AppKit
import Testing
@testable import MessagesLabSidebar

/// A system colours notice may come off the main thread. The sidebar's
/// observer (object: nil) uses `queue: .main`: its palette work runs on
/// main, never on the posting thread (a selector observer ran it there; in
/// Swift 6 code it trapped, #18771).
@MainActor @Suite(.serialized) struct SidebarOffMainNoticeTests {
    /// Where the unread colour was resolved, and what it answers.
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []
        private var darkValue = false
        var dark: Bool {
            get { lock.withLock { darkValue } }
            set { lock.withLock { darkValue = newValue } }
        }
        var resolvedOnMain: [Bool] { lock.withLock { threads } }
        func resolved() { lock.withLock { threads.append(Thread.isMainThread) } }
        func reset() { lock.withLock { threads = [] } }
    }

    @Test func aColoursNoticePostedOffMainRecoloursOnMain() async {
        let probe = Probe()
        let sidebar = SidebarController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        sidebar.unreadColor = NSColor(name: nil) { _ in
            probe.resolved()
            return probe.dark ? NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1) : NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        }
        let before = sidebar.currentPalette.unread
        probe.dark = true  // the colour changes; only the notice tells the sidebar
        probe.reset()

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
                done.resume()
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while sidebar.currentPalette.unread == before, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(sidebar.currentPalette.unread != before, "the notice recolours the sidebar")
        #expect(!probe.resolvedOnMain.isEmpty && probe.resolvedOnMain.allSatisfy { $0 }, "the palette work runs on main: \(probe.resolvedOnMain)")
    }
}
