import AppKit

/// Seam adapter (PATTERNS.md P2): AppKit's local event monitor for modifier changes, delivered
/// to a main-actor handler. A terminal installs one while the pointer is over it, so Command
/// pressed or released there reaches it even without focus (a key event goes only to the
/// focused view), and removes it when the pointer leaves or the view is hidden, parked or leaves its
/// window. Its handler holds the terminal weakly.
@MainActor final class TerminalModifierMonitor {
    private var token: Any?
    private let changed: @MainActor (NSEvent.ModifierFlags) -> Void

    init(_ changed: @escaping @MainActor (NSEvent.ModifierFlags) -> Void) {
        self.changed = changed
    }

    var isInstalled: Bool { token != nil }

    func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [changed] event in
            // main-proof: AppKit runs local event monitors on the main thread, in sendEvent
            MainActor.assumeIsolated { changed(event.modifierFlags) }
            return event
        }
    }

    func remove() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }
}
