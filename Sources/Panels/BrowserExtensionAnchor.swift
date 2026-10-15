import AppKit

/// A toolbar button's position for anchoring an extension popup, read in
/// AppKit at click time.
///
/// SwiftUI's `.global` frame is relative to the hosting view, and Bonsplit
/// and the canvas host each pane in its own hosting view, so the anchor is
/// measured with `NSView.convert(_:to:)` instead.
@MainActor
final class BrowserExtensionAnchor {
    /// The view backing the button (set by ``BrowserExtensionAnchorReader``).
    weak var view: NSView?

    /// The button's frame in its window (AppKit coordinates), or nil while it is off screen.
    var windowFrame: CGRect? {
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}
