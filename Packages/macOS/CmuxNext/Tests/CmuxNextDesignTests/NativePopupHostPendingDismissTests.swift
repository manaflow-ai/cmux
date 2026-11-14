import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A popup whose content measures itself before it shows (Page Info's React bubble) arms the
/// host's dismiss rules first: a dismiss in that wait reaches the owner, which drops the open
/// instead of showing the popup after the user moved on.
@MainActor @Suite(.serialized, .closesItsWindows) struct NativePopupHostPendingDismissTests {
    /// The notices this test posts go here only (a fresh center per test).
    private let center = NotificationCenter()

    @Test func aDismissBeforeTheFirstShowReachesTheOwner() async throws {
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let host = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.tests.popup-pending"), notificationCenter: center)
        defer {
            host.closePanel()
            window.closeAfterTest()
        }
        var dismissed = 0
        host.onDismiss = { dismissed += 1 }

        host.watchBeforeShowing(window)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<20 where dismissed == 0 { await Task.yield() }
        #expect(dismissed == 1, "a deactivation while the popup was getting ready did not drop it")
        #expect(!host.isShown)

        // Dropped: the rules stop until the next open.
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(dismissed == 1)
    }

    @Test func aHideBeforeTheFirstShowDisarms() async throws {
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let host = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.tests.popup-pending-hide"), notificationCenter: center)
        defer {
            host.closePanel()
            window.closeAfterTest()
        }
        var dismissed = 0
        host.onDismiss = { dismissed += 1 }

        host.watchBeforeShowing(window)
        host.hide()
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(dismissed == 0)
    }
}
