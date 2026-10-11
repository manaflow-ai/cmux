import AppKit
import QuartzCore

/// The fade behind a workspace row's hover actions (Lawrence 2026-10-11,
/// cx-qno.22: "Overlay with fade"): the x and the more button draw over the
/// end of the title, which keeps its full width, so nothing moves on hover.
/// A horizontal gradient from clear to the row's own background (the row
/// fill over the sidebar, `Palette.sidebarRowBackground`) hides what lies under
/// the buttons.
final class SidebarActionScrim: NSView {
    private var gradient: CAGradientLayer? { layer as? CAGradientLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient?.startPoint = CGPoint(x: 0, y: 0.5)
        gradient?.endPoint = CGPoint(x: 1, y: 0.5)
        gradient?.actions = ["colors": NSNull(), "locations": NSNull(), "bounds": NSNull(), "position": NSNull()]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    /// Clicks pass through to the row (the buttons above take theirs).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Paints the fade: clear over the first `fade` points, then `color`.
    func paint(_ color: NSColor, fade: CGFloat) {
        let cg = color.cgColor
        gradient?.colors = [cg.copy(alpha: 0) ?? cg, cg, cg]
        let edge = bounds.width > 0 ? min(1, fade / bounds.width) : 0
        gradient?.locations = [0, NSNumber(value: Double(edge)), 1]
    }
}
