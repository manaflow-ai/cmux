import AppKit

/// Gives the keys back when a window under an agent render window becomes key.
///
/// An agent render window (`AgentRenderPanel`) never becomes key, but the Chromium page window of a background tab an
/// agent drives sits under it, and the fork activates a page's window when it shows, creates or focuses it. Any path
/// that does so takes the keys from the window the person types in (NIGHTLY, 2026-11-16: "as i was typing, we lost
/// focus of left terminal"). The keys go back to the last key window outside the render windows, in the same turn.
/// ``ChromiumWindowGuard`` reports each key change (``ChromiumWindowGuard/onBecameKey``).
@MainActor final class AgentRenderKeyReturn {
    private let keyWindows: CEFKeyWindows
    private weak var lastKey: NSWindow?

    init(keyWindows: CEFKeyWindows = .appKit) {
        self.keyWindows = keyWindows
    }

    /// `window` became key: a parked page's window gives the keys back; any other window is remembered.
    func windowBecameKey(_ window: NSWindow) {
        guard Self.isParked(window) else {
            lastKey = window
            return
        }
        guard let back = lastKey, back !== window, back.isVisible else { return }
        keyWindows.makeKey(back)
    }

    /// Whether `window` is an agent render window or under one.
    static func isParked(_ window: NSWindow) -> Bool {
        sequence(first: window, next: \.parent).contains { $0.identifier == .agentRenderWindow }
    }
}
