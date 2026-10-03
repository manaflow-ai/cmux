import AppKit
import CmuxNextDesign

/// The sidebar's inset panel beside the leading rail (Leo, 2026-10-03, the
/// Codex app's skinny strip): one tonal step over the window's backdrop
/// (`Palette.sidebarStep`, from the terminal theme like every chrome
/// color), with only its top leading corner rounded where it meets the
/// rail and the top row. It paints no material of its own: the step is
/// translucent, so a see-through window stays one backdrop under it, and
/// with Reduce Transparency the backdrop below is opaque and the step reads
/// as a solid tone. The root places it under the sidebar, which draws on
/// it unchanged.
final class WindowSidebarPanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerCurve = .continuous
        // Not flipped: the top leading corner is min x, max y.
        layer?.maskedCorners = [.layerMinXMaxYCorner]
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
        performWithTheme { layer.backgroundColor = Palette.sidebarStep.cgColor }
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
