import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// The close key of a window that closes as a whole closes it with `closeWithoutButtonFlash` (its proof is the
/// live diag-close-stall journey, handoff/v224-gate-triage.md: in a test process AppKit skips the button flash,
/// so a nested-loop test passed on the base and was removed). This pins the rule the new path keeps: a window
/// class with its own close (DevTools hides its inspector) keeps it on the key.
@MainActor @Suite(.serialized) struct WindowKeyCloseNoFlashTests {
    final class OwnCloseWindow: NSWindow, WindowKeyClosing {
        var ownCloses = 0
        func closeFromKey() { ownCloses += 1 }
    }

    private static func window<W: NSWindow>(_ type: W.Type) -> W {
        _ = NSApplication.shared
        let window = W(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                       backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aWindowWithItsOwnCloseKeepsIt() {
        let window = Self.window(OwnCloseWindow.self)
        window.orderFront(nil)
        defer { window.close() }
        WindowKeyTable.closeFromKey(window)
        #expect(window.ownCloses == 1)
        #expect(window.isVisible, "the window's own close decides; the key does not close it under it")
    }
}
