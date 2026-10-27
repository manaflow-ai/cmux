import AppKit
import CmuxNextInputCore

// The window scope checks of InputEventTap: a scoped entry and an event compare window numbers, so a
// delivery loop reads no weak reference and asks AppKit for an owner window at most once per stage.
extension InputEventTap {
    /// The window a scoped subscription hears, by window number. A window with no number yet (a
    /// deferred window not shown yet) is read again until it has one.
    final class WindowKey {
        private weak var window: NSWindow?
        private var resolved: Int

        init(window: NSWindow) {
            self.window = window
            resolved = window.windowNumber
        }

        init(number: Int) { resolved = number }

        /// The window's number; 0 or less while it has none.
        var number: Int {
            if resolved <= 0, let window { resolved = window.windowNumber }
            return resolved
        }
    }

    /// One event's window and owner-window numbers for the scope checks of one stage. The owner (the
    /// cmux window of a Chromium page window) is looked up only when a scope needs it, and only once.
    struct EventWindows {
        private let event: NSEvent
        private let window: Int
        private var owner: Int?

        init(_ event: NSEvent, window: Int? = nil, owner: Int? = nil) {
            self.event = event
            self.window = window ?? event.windowNumber
            self.owner = owner
        }

        /// Whether the event's window, or the window that owns it, is the window numbered `number`.
        mutating func belongs(to number: Int) -> Bool {
            guard number > 0 else { return false }
            if number == window { return true }
            if owner == nil { owner = event.window.map { InputEventRecord.ownerWindow(of: $0).windowNumber } ?? 0 }
            return number == owner
        }
    }
}
