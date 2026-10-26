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
}
