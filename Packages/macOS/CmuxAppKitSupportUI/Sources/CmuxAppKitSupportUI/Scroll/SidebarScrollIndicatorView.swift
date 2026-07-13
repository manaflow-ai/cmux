import AppKit
import QuartzCore

@MainActor
final class SidebarScrollIndicatorView: NSView {
    private static let minimumKnobHeight: CGFloat = 24

    private weak var scrollView: NSScrollView?
    private let knobLayer = CALayer()

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(knobLayer)
        knobLayer.cornerRadius = 3
        alphaValue = 0
        isHidden = true
        updateKnobColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateKnobColor()
    }

    @discardableResult
    func updateGeometry() -> Bool {
        guard let scrollView,
              let documentView = scrollView.documentView else { return false }

        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = documentView.bounds.height
        let trackHeight = bounds.height
        let maximumOffset = documentHeight - viewportHeight
        guard viewportHeight > 0, trackHeight > 0, maximumOffset > 1 else { return false }

        let knobHeight = min(
            trackHeight,
            max(Self.minimumKnobHeight, trackHeight * viewportHeight / documentHeight)
        )
        let rawOffset = scrollView.contentView.bounds.minY
        let progress = min(max(rawOffset / maximumOffset, 0), 1)
        let visualProgress = documentView.isFlipped ? progress : 1 - progress
        let knobY = (1 - visualProgress) * (trackHeight - knobHeight)
        knobLayer.frame = CGRect(x: 0, y: knobY, width: bounds.width, height: knobHeight)
        return true
    }

    private func updateKnobColor() {
        knobLayer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7).cgColor
    }
}
