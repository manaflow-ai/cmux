import AppKit

/// Native material backdrop that uses system glass when requested and available.
@MainActor
final class SidebarVisualEffectBackground: NSView {
    static var liquidGlassAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    private let effectView: NSView

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        opacity: Double = 1,
        tintColor: NSColor? = nil,
        cornerRadius: CGFloat = 0,
        preferLiquidGlass: Bool = false
    ) {
        if preferLiquidGlass,
           let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            effectView = glassClass.init(frame: .zero)
        } else {
            effectView = NSVisualEffectView()
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.wantsLayer = true
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(
            material: material,
            blendingMode: blendingMode,
            state: state,
            opacity: opacity,
            tintColor: tintColor,
            cornerRadius: cornerRadius
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func update(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        state: NSVisualEffectView.State,
        opacity: Double,
        tintColor: NSColor?,
        cornerRadius: CGFloat
    ) {
        let clampedOpacity = max(0, min(1, opacity))
        effectView.alphaValue = clampedOpacity
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = cornerRadius > 0

        if effectView.className == "NSGlassEffectView" {
            let selector = NSSelectorFromString("setTintColor:")
            if effectView.responds(to: selector) {
                effectView.perform(selector, with: tintColor)
            }
        } else if let visualEffect = effectView as? NSVisualEffectView {
            visualEffect.material = material
            visualEffect.blendingMode = blendingMode
            visualEffect.state = state
            visualEffect.layerContentsRedrawPolicy = .onSetNeedsDisplay
            visualEffect.needsDisplay = true
        }
    }
}
