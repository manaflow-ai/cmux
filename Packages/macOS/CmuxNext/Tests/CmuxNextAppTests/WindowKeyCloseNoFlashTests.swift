import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// The close key of a window that closes as a whole (Settings, Page Info, a browser popup, DevTools, a
/// kindless closable window: `WindowKeyTable`'s `.closeWindow`) called `performClose(nil)`: AppKit's close
/// button flash, a nested event-tracking run loop of about 100 ms on the key turn (as Close Window did on
/// main windows, v2.2.4-opt, handoff/v224-gate-triage.md). It closes in the key's turn now; a window class
/// with its own close (DevTools hides its inspector) keeps it.
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

    private static func nestedRunLoops(during body: () -> Void) -> Int {
        var entries = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.entry.rawValue, true, 0) { _, _ in entries += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        body()
        return entries
    }

    @Test func aPlainWindowClosesInTheKeysTurnWithNoNestedRunLoop() {
        let window = Self.window(NSWindow.self)
        window.orderFront(nil)
        defer { window.close() }
        let entries = Self.nestedRunLoops { WindowKeyTable.closeFromKey(window) }
        #expect(entries == 0, "the close key ran \(entries) nested run loop(s) (the close button's flash)")
        #expect(!window.isVisible, "the window did not close in the key's turn")
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
