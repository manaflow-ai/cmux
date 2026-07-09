public import AppKit
public import CoreGraphics

/// Live-view exact-rect reconciliation for the tmux-style pane overlay.
///
/// ``TmuxPaneOverlayGeometry`` resolves overlay rectangles from Bonsplit value
/// snapshots. When the host pane view is mounted in a window the overlay can be
/// placed more precisely from the view's own measured frame than from the
/// snapshot; these helpers measure that exact rect and decide when to prefer it
/// over the snapshot-derived pane rect. They are pure geometry over AppKit views
/// and `CGRect`s, so they hold no state and live alongside the snapshot math.
extension TmuxPaneOverlayGeometry {
    /// Measures a descendant view's frame in its window's content-view
    /// coordinate space.
    /// - Parameters:
    ///   - targetView: the pane's hosted content view.
    ///   - contentView: the window content view the overlay is placed within.
    /// - Returns: `targetView`'s bounds converted into `contentView`'s
    ///   coordinate space, or `nil` when the two views are not in the same live
    ///   window, the target is unattached, or the converted rect is degenerate
    ///   (1pt or less on either axis).
    // @MainActor: reads NSView window/superview/bounds + convert(_:to:/from:),
    // all main-actor under Swift 6.1 (CI Xcode 16.4); runs on the main-thread
    // overlay-placement path. The sibling pure-CGRect chooser stays nonisolated.
    @MainActor
    public static func exactRect(
        for targetView: NSView,
        in contentView: NSView
    ) -> CGRect? {
        guard let contentWindow = contentView.window,
              let targetWindow = targetView.window,
              contentWindow === targetWindow,
              targetView.superview != nil else {
            return nil
        }

        let rectInWindow = targetView.convert(targetView.bounds, to: nil)
        let rectInContent = contentView.convert(rectInWindow, from: nil)
        guard rectInContent.width > 1, rectInContent.height > 1 else { return nil }
        return rectInContent
    }

    /// Chooses between the live view-measured exact rect and the
    /// snapshot-derived pane rect for the window-content overlay.
    /// - Parameters:
    ///   - exactRect: the live view-measured rect, if any.
    ///   - paneRect: the snapshot-derived pane rect, if any.
    /// - Returns: `exactRect` when it is non-degenerate and fits within
    ///   `paneRect` (within a 0.5pt tolerance on every edge), otherwise
    ///   `paneRect`; falls back to `exactRect` when there is no `paneRect`.
    public static func preferredWindowOverlayRect(
        exactRect: CGRect?,
        paneRect: CGRect?
    ) -> CGRect? {
        guard let paneRect else { return exactRect }
        guard let exactRect,
              exactRect.width > 1,
              exactRect.height > 1 else {
            return paneRect
        }

        let tolerance: CGFloat = 0.5
        let exactFitsWithinPane =
            exactRect.minX >= paneRect.minX - tolerance &&
            exactRect.maxX <= paneRect.maxX + tolerance &&
            exactRect.minY >= paneRect.minY - tolerance &&
            exactRect.maxY <= paneRect.maxY + tolerance
        return exactFitsWithinPane ? exactRect : paneRect
    }
}
