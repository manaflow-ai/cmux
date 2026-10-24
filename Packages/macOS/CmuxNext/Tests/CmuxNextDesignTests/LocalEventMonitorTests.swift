import AppKit
@testable import CmuxNextDesign
import Testing

/// ``LocalEventMonitor`` holds the `NSEvent` local monitor a hover card coordinator installs (its
/// dismissal monitor and its move watch's monitor). `remove()` takes the monitor out of the app:
/// an event the app dispatches after it no longer reaches the handler. The coordinator's release
/// test checks that a released coordinator calls `remove()` (`isInstalled`); this checks what
/// `remove()` does to the app's event dispatch.
@MainActor
@Suite(.serialized) struct LocalEventMonitorTests {
    /// Counts the events a monitor's handler saw (a main-actor class, so the handler may mutate it).
    @MainActor private final class Seen {
        var count = 0
    }

    private static func keyDown() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
    }

    /// A swallowing monitor that counts what it saw: no window or menu acts on the test's key press.
    private static func swallowing(_ seen: Seen) -> LocalEventMonitor {
        LocalEventMonitor(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { _ in
            seen.count += 1
            return nil
        })
    }

    @Test func aRemovedMonitorSeesNoMoreEvents() throws {
        let app = NSApplication.shared
        let seen = Seen()
        let monitor = Self.swallowing(seen)
        defer { monitor.remove() }
        #expect(monitor.isInstalled)
        try app.sendEvent(Self.keyDown())
        try #require(seen.count == 1, "an installed monitor did not see the key press the app dispatched")

        // A second swallowing monitor, installed before the first one leaves, takes the next press:
        // it never reaches a window another suite made key, and its count shows the app dispatched
        // it to the local monitors. Only one monitor is installed at each press, so the order AppKit
        // runs monitors in does not matter.
        let guardSeen = Seen()
        let guardMonitor = Self.swallowing(guardSeen)
        defer { guardMonitor.remove() }
        monitor.remove()
        #expect(!monitor.isInstalled)
        try app.sendEvent(Self.keyDown())
        try #require(guardSeen.count == 1, "the app did not dispatch the second key press to its local monitors")
        #expect(seen.count == 1, "a removed monitor still saw the key press the app dispatched")

        monitor.remove()
        #expect(!monitor.isInstalled, "a second remove() put the monitor back")
    }
}
