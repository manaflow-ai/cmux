import AppKit

/// The column strip's clip as layer structure (p03-rendering-023): beside docked columns, the strip's
/// pane hosts sit in this view, whose layer masks to its bounds, so one rect clips every strip pane
/// whatever its spring or the strip's pan does, and no host carries a mask for it. Docked columns are
/// this view's siblings, stacked above it (`ScreenContentView.rank`). Chrome clips a scroller's
/// contents the same way: a clip node on the scroller's container layer, not a mask per child
/// (`cc/trees/clip_node.h`, `ui/views/controls/scroll_view.cc` `contents_viewport_`).
///
/// Its bounds origin is its frame origin, so a host's frame here is in the screen's coordinates, as it
/// is directly in the screen: moving a host between the two keeps its frame.
final class StripClipContainerView: NSView {
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

    /// Clips the hosts to `rect` (the screen's coordinates). Returns true when the clip changed.
    @discardableResult
    func clip(to rect: CGRect) -> Bool {
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
