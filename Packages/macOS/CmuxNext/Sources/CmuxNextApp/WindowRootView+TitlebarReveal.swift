import AppKit
import CmuxNextDesign

// R83: every title bar button but the sidebar toggle (Back, Forward) and a
// glass patch under the traffic lights stay hidden until the pointer is
// over the top row, then fade in, in place, through the one hover-reveal
// mechanism (HoverReveal). Shortcuts and the palette reach the same actions
// while they are hidden; keyboard focus on a hidden button reveals them.
extension WindowRootView {
    func setUpTitlebarReveal() {
        titlebarReveal.add(toolbarBand.backButton)
        titlebarReveal.add(toolbarBand.forwardButton)
        // The glass patch is a hover cue only: it never shows at rest.
        trafficLightsGlass.alphaValue = 0
        titlebarReveal.onChange = { [weak self] revealed in
            guard let self else { return }
            let glass = trafficLightsGlass
            Motion.animate(.hover, in: glass) { glass.animator().alphaValue = revealed && self.titlebarReveal.state.pointerInside ? 1 : 0 }
        }
        applyTitlebarButtonsMode()
    }

    /// `window.titlebarButtons`: hover hides the buttons at rest; always
    /// shows them.
    func applyTitlebarButtonsMode() {
        titlebarReveal.isEnabled = DesignSettings.shared.titlebarButtons == .hover
    }

    /// The region spans the top row; the glass patch covers the traffic
    /// lights with a small margin.
    func layoutTitlebarReveal(rowHeight: CGFloat) {
        titlebarRevealRegion.frame = CGRect(x: 0, y: bounds.maxY - rowHeight, width: bounds.width, height: rowHeight)
        guard let window, let lights = WindowTitlebar.trafficLightsFrame(in: window) else {
            trafficLightsGlass.frame = .zero
            return
        }
        let local = convert(lights, from: nil).insetBy(dx: -Metrics.space2, dy: -Metrics.space1)
        trafficLightsGlass.frame = local
    }
}

/// A view that tracks the pointer but never takes a click.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The hover patch behind the traffic lights: the chrome hover fill on a
/// rounded rect, repainted with the theme. Takes no clicks.
final class TrafficLightsPatch: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.panelCornerRadius
        layer?.cornerCurve = .continuous
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { layer?.backgroundColor = Palette.hoverFill.cgColor }
    }
}
