import AppKit
import CmuxNextDesign

/// The single rounded frame behind the sidebar and main pane beside the
/// leading rail. It paints the same surface token as the window backdrop,
/// so the rail and frame read as one glass surface without a lighter strip.
/// The root places it below both columns; sidebar and pane content remain
/// transparent chrome over that shared frame.
final class WindowSidebarPanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    /// Clicks reach the sidebar above it, or the root's empty space.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        paint()
    }

    /// Applies the corner and the fill now (the root calls it when the
    /// panel appears and on theme changes, so it never shows a frame late).
    func paint() {
        guard let layer else { return }
        layer.cornerRadius = Metrics.panelCornerRadius
        performWithTheme { layer.backgroundColor = Palette.surfaceBackground.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
}
