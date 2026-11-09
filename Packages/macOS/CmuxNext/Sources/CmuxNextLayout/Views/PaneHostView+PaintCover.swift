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
/// out on `viewDidHide` only. A tab switch that shows such content inside a covered pane turns the cover into a hide
/// first (``parkedContentWillShow(_:)``, ZOOM VARIANTS 10). Known edge: a paint hold that keeps a terminal beside a new
/// page at the cover covers both by paint.
extension PaneHostView {
    var isParkedOffScreen: Bool { isCoveredByPaint }

    /// Whether the shown part of `view`'s subtree (hidden subtrees skipped) has a ``ParkingObserver``. Read once at a
    /// zoom's cover, never in a key turn.
    static func showsParkingObserver(_ view: NSView) -> Bool {
        !view.isHidden && wouldShowParkingObserver(view)
    }

    /// ``showsParkingObserver(_:)`` with `view` itself taken as shown: content about to show.
    static func wouldShowParkingObserver(_ view: NSView) -> Bool {
        view is any ParkingObserver || view.subviews.contains { showsParkingObserver($0) }
    }

    /// A tab switch in this covered pane is about to show `view` (``AppKit/NSView/willShowContent(_:)``). Content that
    /// does not stop on parking (a page: its window orders in when no ancestor is hidden, whatever the paint) would
    /// show over the zoomed pane, so the paint cover becomes a hide before it shows. The unzoom then shows this pane by
    /// unhiding it (``LayoutViewContext``), and the page with it.
    func parkedContentWillShow(_ view: NSView) {
        guard isCoveredByPaint, !Self.wouldShowParkingObserver(view) else { return }
        isHidden = true
        chrome.isHidden = true
        coverByPaint(false) // full paint again, under the hide; hidden, it walks no parking observer
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
