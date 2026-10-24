import AppKit
import CmuxNextSignposts
import CmuxNextTerminal

/// The always-on `key.frame` interval (``SignpostName/keyToFrame``): from the app dispatching a key-down to the
/// end of the Core Animation commit that ends that turn (``CommitBoundary``). Message:
/// `target=<view|terminal> age_ms=<the key's age when its dispatch began>`, so a reader adds the wait in the event
/// queue to the interval. For a text view (the Home composer, the omnibar, a field) that commit carries the
/// typed character. For a terminal it carries the key's own work only: the echo comes back from the shell in a
/// later frame (presented off the main thread since PL-ghostty's G9), so `target=terminal` rows are the main
/// thread's share of the key, not key to glyph.
@MainActor
struct KeyFrameSignpost {
    /// Begins the interval for `event`, a key-down `window` dispatches now; it ends after this turn's commit.
    func begin(_ event: NSEvent, in window: NSWindow?) {
        let signposter = Signposter.key
        guard signposter.isEnabled, event.type == .keyDown else { return }
        let target = window?.firstResponder is TerminalSurfaceView ? "terminal" : "view"
        let age = event.timestamp > 0 ? max(0, ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000 : -1
        let interval = signposter.begin(.keyToFrame, "target=\(target) age_ms=\(String(format: "%.2f", age))")
        CommitBoundary().after { outcome in signposter.end(.keyToFrame, interval, outcome) }
    }
}
