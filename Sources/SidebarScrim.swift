import AppKit
import QuartzCore

@MainActor
final class SidebarWorkspaceScrollEdgeFadeMaskView: NSView {
    var topHeight: CGFloat = 0 { didSet { needsLayout = true } }
    var bottomHeight: CGFloat = 0 { didSet { needsLayout = true } }

    private let topGradient = CAGradientLayer()
    private let bottomGradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let colors = [0.05, 0.25, 0.65, 1.0].map {
            NSColor.black.withAlphaComponent($0).cgColor
        }
        topGradient.colors = colors
        topGradient.locations = [0, 0.33, 0.66, 1]
        topGradient.startPoint = CGPoint(x: 0.5, y: 1)
        topGradient.endPoint = CGPoint(x: 0.5, y: 0)
        bottomGradient.colors = Array(colors.reversed())
        bottomGradient.locations = [0, 0.33, 0.66, 1]
        bottomGradient.startPoint = CGPoint(x: 0.5, y: 1)
        bottomGradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(topGradient)
        layer?.addSublayer(bottomGradient)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topGradient.frame = CGRect(
            x: 0,
            y: max(0, bounds.height - topHeight),
            width: bounds.width,
            height: min(topHeight, bounds.height)
        )
        bottomGradient.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: min(bottomHeight, bounds.height)
        )
        CATransaction.commit()
    }
}
