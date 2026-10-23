import AppKit

/// The window an input event came from, for the length of its dispatch.
struct EventOrigin {
    /// The cmux window that owns the event's window.
    weak var controller: WindowController?
    /// The key window when the dispatch began.
    weak var keyAtStart: NSWindow?
}

extension WindowManager {
    /// Runs `body`, the dispatch of an input event from `window`.
    func dispatching<T>(eventFrom window: NSWindow?, _ body: () throws -> T) rethrows -> T {
        try body()
    }
}
