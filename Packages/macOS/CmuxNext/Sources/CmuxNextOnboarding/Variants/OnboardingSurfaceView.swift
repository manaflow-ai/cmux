import AppKit
import CmuxNextDesign

/// A variant's surface behind its content. The window's one backdrop (the
/// main window's material and tint, `NSWindow.install`) is the surface of
/// the full-window variants (full glass, glass controls, opaque), so they
/// draw nothing of their own (plans/cmux-next/windows.md, one backdrop
/// rule); the floating panel variant draws an inset glass card over it.
/// Reduce Transparency makes the backdrop opaque.
final class OnboardingSurfaceView: NSView {
    /// How much of the theme background sits over the floating panel's glass.
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
        if self.surface == .glassPanel {
            fill.layer?.cornerRadius = Self.panelRadius
            let glass = Glass.makePanel(content: fill, cornerRadius: Self.panelRadius)
            pin(glass, inset: Self.panelInset)
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
        guard surface == .glassPanel else { return }
        fill.layer?.backgroundColor = Palette.windowBackground.withAlphaComponent(Self.glassFillAlpha).cgColor
    }
}
