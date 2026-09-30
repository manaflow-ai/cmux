import AppKit
import CmuxNextDesign
import QuartzCore

/// Wraps one App-provided pane view. Its focus ring and inactive dim
/// (`chrome`) live in the layout's `OverlayPlane`, not in this view, so they
/// draw above content that is a child window (Chromium pages); the root
/// keeps them on this view's displayed frame.
final class PaneHostView: NSView {
    let pane: PaneID
    let content: NSView
    let chrome = PaneOverlayView()

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func setChrome(showsRing: Bool, dim: CGFloat, ringWidth: CGFloat) {
        chrome.update(showsRing: showsRing, dim: dim, ringWidth: ringWidth)
    }
}

/// Non-interactive overlay: subtle gray ring (never blue) and a dim layer.
final class PaneOverlayView: NSView {
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

    /// Whether the ring is showing (for `debug.layers`).
    var showsRing: Bool { ring.opacity > 0 }

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
