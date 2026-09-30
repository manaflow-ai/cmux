import AppKit
import CmuxNextDesign
import QuartzCore

/// Wraps one App-provided pane view and draws the focus ring and inactive dim
/// above it without taking hits.
final class PaneHostView: NSView {
    let pane: PaneID
    let content: NSView
    private let overlay = PaneOverlayView()

    init(pane: PaneID, content: NSView) {
        self.pane = pane
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = bounds
        addSubview(content)
        overlay.autoresizingMask = [.width, .height]
        overlay.frame = bounds
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func setChrome(showsRing: Bool, dim: CGFloat, ringWidth: CGFloat) {
        overlay.update(showsRing: showsRing, dim: dim, ringWidth: ringWidth)
    }
}

/// Non-interactive overlay: subtle gray ring (never blue) and a dim layer.
private final class PaneOverlayView: NSView {
    private let ring = CALayer()
    private let dimLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ring.borderWidth = 1
        ring.opacity = 0
        dimLayer.opacity = 0
        layer?.addSublayer(dimLayer)
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        dimLayer.frame = bounds
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func update(showsRing: Bool, dim: CGFloat, ringWidth: CGFloat) {
        applyColors()
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16)
        ring.borderWidth = ringWidth
        ring.opacity = showsRing ? 1 : 0
        dimLayer.opacity = Float(dim)
        CATransaction.commit()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.borderColor = Palette.focusRing.withAlphaComponent(0.55).cgColor
            dimLayer.backgroundColor = Palette.contentBackground.withAlphaComponent(1).cgColor
        }
    }
}
