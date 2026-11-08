import AppKit
import CmuxNextDesign
import QuartzCore

/// A zoom's covered pane covered by paint only (ZOOM VARIANTS 9, fork only, never merged): the host stays in the tree,
/// unhidden, at opacity 0 (its ring too), takes no click (`hitTest`), lists nothing to accessibility, and parks its
/// subtree (``ParkingContainer``: a terminal stops drawing as a hidden one does). The cover and the uncover change
/// paint and parking only, so the unzoom's key turn flips no `isHidden`: AppKit's hidden-ancestor walk, its KVO and the
/// window's cursor-rect and drag-region rebuild for each covered pane are gone from that turn (ZOOM VARIANTS 8 profile,
/// C3 K6 out: `_setHidden` 0.8 ms under `LayoutViewContext.host(for:)`).
/// Only for content that stops on parking (``LayoutPaneContentProvider/coversByPaint(_:content:)``): a page window orders
/// out on `viewDidHide` only. Known edges: a tab switch to a page inside a covered pane would show that page's window (the
/// answer is for the content at the cover); a paint hold that keeps a terminal beside a new page at the cover covers both
/// by paint.
extension PaneHostView {
    var isParkedOffScreen: Bool { isCoveredByPaint }

    /// Whether the shown part of `view`'s subtree (hidden subtrees skipped) has a ``ParkingObserver``. Read once at a
    /// zoom's cover, never in a key turn.
    static func showsParkingObserver(_ view: NSView) -> Bool {
        guard !view.isHidden else { return false }
        if view is any ParkingObserver { return true }
        return view.subviews.contains { showsParkingObserver($0) }
    }

    /// Covers (`covered`) or uncovers this pane by paint, with no implicit animation, and tells the content's parking
    /// observers. An uncover shows it at full opacity; a film that fades it in sets its own start after this.
    func coverByPaint(_ covered: Bool) {
        guard covered != isCoveredByPaint else { return }
        isCoveredByPaint = covered
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [layer, chrome.layer].compactMap({ $0 }) {
            layer.removeAnimation(forKey: "opacity")
            layer.opacity = covered ? 0 : 1
        }
        CATransaction.commit()
        notifyParkingChange()
    }
}
