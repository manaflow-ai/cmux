public import AppKit

/// Native resolved backdrop for one window-chrome role.
@MainActor
public final class WindowBackdropLayer: NSView {
    private var role: WindowBackdropRole
    private var snapshot: WindowAppearanceSnapshot

    /// Creates a native backdrop for a chrome role.
    public init(role: WindowBackdropRole, snapshot: WindowAppearanceSnapshot) {
        self.role = role
        self.snapshot = snapshot
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)
        rebuild()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Reapplies a changed role or appearance snapshot.
    public func update(role: WindowBackdropRole, snapshot: WindowAppearanceSnapshot) {
        self.role = role
        self.snapshot = snapshot
        rebuild()
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        layer?.backgroundColor = nil

        switch snapshot.policy(for: role) {
        case let .ghosttyTerminalBackdrop(color, opacity, _):
            install(LayerBackedBackdropColor(color: color.withAlphaComponent(opacity)))
        case let .sidebarMaterial(materialPolicy):
            guard !materialPolicy.usesWindowLevelGlass else { return }
            let usingNativeLiquidGlass = materialPolicy.preferLiquidGlass &&
                SidebarVisualEffectBackground.liquidGlassAvailable
            if let material = materialPolicy.material {
                install(SidebarVisualEffectBackground(
                    material: material,
                    blendingMode: materialPolicy.blendingMode,
                    state: materialPolicy.state,
                    opacity: materialPolicy.opacity,
                    tintColor: materialPolicy.tintColor,
                    cornerRadius: materialPolicy.cornerRadius,
                    preferLiquidGlass: materialPolicy.preferLiquidGlass
                ))
            }
            if !usingNativeLiquidGlass {
                install(LayerBackedBackdropColor(color: materialPolicy.tintColor))
            }
        case .clear:
            break
        }
    }

    private func install(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
