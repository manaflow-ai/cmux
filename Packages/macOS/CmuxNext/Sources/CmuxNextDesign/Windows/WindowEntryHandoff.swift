public import AppKit

/// Keeps a view in its window while a container that is in no window yet shows it.
///
/// A container built outside the window (a new workspace's pane, the pane of a screen that replaces
/// another) that adds a view which is still in the window takes the view out of the window, and the
/// container's own entry puts it back in the same turn. AppKit pays for both moves: a Chromium page's
/// view that leaves its window orders its page window out and AppKit waits for the window server
/// (`-[NSWindow _doOrderWindow:]`, 88-110 ms per Cmd-N on a fleet mini, 2026-10-24). The container asks
/// ``defers(_:to:)`` before it adds the view and takes ``entered(_:)``'s view when it enters a window.
///
/// ```swift
/// if let view, !handoff.defers(view, to: contentHost) { install(view) }
/// // viewDidMoveToWindow:
/// if let view = handoff.entered(contentHost), view === content { show(view) }
/// ```
@MainActor public struct WindowEntryHandoff {
    private weak var view: NSView?
    private weak var from: NSView?

    /// No view waits.
    public init() {}

    /// Whether `view` waits for `host` to enter a window: `host` is in no window, and `view` is in one
    /// under another superview. False forgets any view that waited (the caller adds `view` now).
    /// - Parameters:
    ///   - view: The view the container shows.
    ///   - host: The container's view that `view` goes in.
    /// - Returns: True when the caller must not add `view` yet.
    public mutating func defers(_ view: NSView, to host: NSView) -> Bool {
        guard host.window == nil, view.window != nil, let superview = view.superview, superview !== host else {
            (self.view, from) = (nil, nil)
            return false
        }
        (self.view, from) = (view, superview)
        return true
    }

    /// The view that waited, once `host` is in a window; nil when none waits, `host` is still in no
    /// window, or the view moved meanwhile (another container took it). It waits no longer once `host`
    /// is in a window.
    /// - Parameter host: The container's view that the waiting view goes in.
    /// - Returns: The view to add to `host` now.
    public mutating func entered(_ host: NSView) -> NSView? {
        guard host.window != nil, let waiting = view else { return nil }
        defer { (view, from) = (nil, nil) }
        return waiting.superview === from ? waiting : nil
    }
}
