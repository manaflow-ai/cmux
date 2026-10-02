import AppKit
import CmuxNextDesign

/// Draws a variant's surface behind its content: full-window glass (theme
/// background at partial alpha over it, so light themes stay light), an
/// inset floating glass panel, or the opaque theme background. Reduce
/// Transparency always gets the opaque background.
final class OnboardingSurfaceView: NSView {
    /// How much of the theme background sits over full-window glass.
    static let glassFillAlpha: CGFloat = 0.7
    /// The floating panel's inset and radius.
    static let panelInset: CGFloat = 12
    static let panelRadius: CGFloat = 20

    let surface: OnboardingSurface
    private let fill = NSView()
    private var loop: RenderLoop?

    init(surface: OnboardingSurface, content: NSView) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        self.surface = reduced ? .opaque : surface
        super.init(frame: NSRect(origin: .zero, size: OnboardingMetrics.windowSize))
        autoresizingMask = [.width, .height]
        fill.wantsLayer = true
        fill.layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        switch self.surface {
        case .fullGlass:
            let glass = Glass.makePanel(content: fill, cornerRadius: 0)
            pin(glass, inset: 0)
        case .glassPanel:
            fill.layer?.cornerRadius = Self.panelRadius
            let glass = Glass.makePanel(content: fill, cornerRadius: Self.panelRadius)
            pin(glass, inset: Self.panelInset)
        case .glassControls, .opaque:
            pin(fill, inset: 0)
        }
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let inset = self.surface == .glassPanel ? Self.panelInset : 0
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        loop = RenderLoop { [weak self] in
            _ = ThemeStore.shared.input
            self?.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The window is transparent only around a floating panel.
    var needsTransparentWindow: Bool { surface != .opaque && surface != .glassControls }

    private func pin(_ view: NSView, inset: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    private func applyColors() {
        let opaque = surface == .opaque || surface == .glassControls
        fill.layer?.backgroundColor = Palette.windowBackground.withAlphaComponent(opaque ? 1 : Self.glassFillAlpha).cgColor
    }
}
