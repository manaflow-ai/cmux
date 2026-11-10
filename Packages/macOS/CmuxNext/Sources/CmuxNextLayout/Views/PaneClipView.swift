import AppKit
import QuartzCore

/// The rounded clip around a pane's content. `masksToBounds` with a corner
/// radius clips every sublayer, Metal layers included. Corners are circular
/// (not continuous) so the Chromium page mask, a circular-arc path built
/// from this layer's radius, matches them exactly.
final class PaneClipView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    func setCornerRadius(_ radius: CGFloat) {
        guard let layer, layer.cornerRadius != radius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        CATransaction.commit()
    }

    /// The ground under held content (``showHeldGround(_:cornerRadius:in:)``): in the view tree only while it shows.
    private let heldGround = PaneHeldGroundView()

    /// SPLIT OPEN CHAT: content its provider holds in motion (an agent chat) has its REST size from a spring's first
    /// frame (`PaneHostView.contentFrame`). A pane that is still larger than its rest (the pane a Split Down halves)
    /// had nothing between that content's edge and its own, so the window's color showed there for the frames of the
    /// spring (2 to 7 at 120 Hz). Chromium shows a resized page's old content on the page's own ground until the new
    /// frame comes; a pane does the same: `color` (the content's own ground, `NSView.paneGroundColor`) fills `rect`
    /// (the pane's area under its header, in this view's coordinates) below the content, in the frame that places
    /// the pane. Nothing waits and no content lays out again. Nil, a translucent color or an empty rect removes it.
    func showHeldGround(_ color: CGColor?, cornerRadius: CGFloat = 0, in rect: CGRect = .zero) {
        guard let color, color.alpha >= 1, rect.width > 0, rect.height > 0 else {
            if heldGround.superview != nil { heldGround.removeFromSuperview() }
            return
        }
        if heldGround.superview !== self { addSubview(heldGround, positioned: .below, relativeTo: nil) }
        if heldGround.frame != rect { heldGround.frame = rect }
        guard let ground = heldGround.layer, ground.backgroundColor != color || ground.cornerRadius != cornerRadius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ground.backgroundColor = color
        ground.cornerRadius = cornerRadius
        CATransaction.commit()
    }
}

/// A pane's ground under its held content (``PaneClipView/showHeldGround(_:cornerRadius:in:)``): a color, no clicks.
private final class PaneHeldGroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
