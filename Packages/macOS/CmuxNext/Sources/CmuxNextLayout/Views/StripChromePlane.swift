import AppKit

/// One screen's strip rings and dims in the overlay plane. While the strip's
/// hosts sit in the motion container (`ScreenContentView.stripDividersInContainer`), their
/// `PaneOverlayView`s sit here, laid out at the hosts' laid-out frames, and the container gives this
/// view's layer every translation it takes (`StripClipContainerView.companion`): a strip pan moves
/// the rings and dims with one more layer property, not one frame per pane. Chrome keeps what moves
/// with scrolled content in the scroller's transform subtree the same way (`cc/trees/transform_node.h`).
///
/// It covers the overlay plane exactly (its frame is the plane's bounds), so a ring's frame here is in
/// the layout root's coordinates, as it is directly in the plane. It sits below every other overlay:
/// strip panes are below the docks and a zooming pane in the screen's stacking.
final class StripChromePlane: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The rings' frames are the overlay sync's; a plane resize moves none of them.
        autoresizesSubviews = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
