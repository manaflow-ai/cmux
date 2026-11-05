import AppKit

/// A rounded view filled with a dynamic color that follows the appearance (light and dark), for the agent
/// pane's bubbles, tabs and composer.
final class HomeAgentFillView: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }
    var radius: CGFloat { didSet { needsDisplay = true } }

    init(fill: NSColor, radius: CGFloat) {
        self.fill = fill
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // updateLayer runs with the view's effective appearance current: the dynamic color resolves for it.
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }
}
