import AppKit

/// The column strip's clip as layer structure (p03-rendering-023): the strip's pane hosts sit in this
/// view, whose layer masks to its bounds, so one rect clips every strip pane whatever its spring or the
/// strip's pan does, and no host carries a mask for it. Docked columns are this view's siblings, stacked
/// above it (`ScreenContentView.rank`). Chrome clips a scroller's contents the same way: a clip node on
/// the scroller's container layer, not a mask per child (`cc/trees/clip_node.h`,
/// `ui/views/controls/scroll_view.cc` `contents_viewport_`).
///
/// A host stays in it while one of its panes zooms (no host changes parent for a zoom, so the focused
/// pane keeps its keys): the container is then lifted, its frame the whole screen and stacked above
/// the docks, and the hosts that stay under the zooming pane keep the strip's range through masks of
/// their own, set once when the zoom starts (`ScreenContentView.heldStripClip`).
///
/// Its bounds origin is its frame origin, so a host's frame here is in the screen's coordinates, as it
/// is directly in the screen: moving a host between the two keeps its frame.
final class StripClipContainerView: NSView {
    /// The strip's range (the screen's coordinates) the hosts show in: the frame, unless lifted.
    private(set) var range: CGRect = .zero
    /// True while a zoom of one of its hosts lifts the clip (`place(range:liftedTo:)`).
    private(set) var isLifted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // The hosts' frames are the layout's; a clip that moves resizes none of them.
        autoresizesSubviews = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    /// Clips the hosts to `range` (the screen's coordinates), or to `lifted` (the screen's bounds) while
    /// a zoom of one of them is in flight. Returns true when the frame changed.
    @discardableResult
    func place(range: CGRect, liftedTo lifted: CGRect?) -> Bool {
        self.range = range
        isLifted = lifted != nil
        let rect = lifted ?? range
        guard frame != rect || bounds.origin != rect.origin else { return false }
        frame = rect
        setBoundsOrigin(rect.origin)
        return true
    }

    /// Clicks outside every host go to the screen, as they do with no container.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
