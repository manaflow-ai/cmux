public import SwiftUI
import AppKit

/// SwiftUI layer that renders the resolved backdrop for one chrome role.
public struct WindowBackdropLayer: View {
    private let role: WindowBackdropRole
    private let snapshot: WindowAppearanceSnapshot

    /// Creates a backdrop layer for a chrome role.
    public init(role: WindowBackdropRole, snapshot: WindowAppearanceSnapshot) {
        self.role = role
        self.snapshot = snapshot
    }

    /// Rendered backdrop body.
    public var body: some View {
        backdrop(for: snapshot.policy(for: role))
    }

    @ViewBuilder
    private func backdrop(for policy: WindowBackdropPolicy) -> some View {
        switch policy {
        case let .ghosttyTerminalBackdrop(color, opacity, _):
            let backdropColor = color.withAlphaComponent(opacity)
            switch role {
            case .windowRoot:
                Color(nsColor: backdropColor)
            case .terminalCanvas, .bonsplitChrome, .titlebar, .leftSidebar, .rightSidebar, .browserSurface:
                LayerBackedBackdropColor(color: backdropColor)
            }
        case let .sidebarMaterial(materialPolicy):
            ZStack {
                let usingNativeLiquidGlass = materialPolicy.preferLiquidGlass &&
                    SidebarVisualEffectBackground.liquidGlassAvailable
                if let material = materialPolicy.material,
                   !materialPolicy.usesWindowLevelGlass {
                    SidebarVisualEffectBackground(
                        material: material,
                        blendingMode: materialPolicy.blendingMode,
                        state: materialPolicy.state,
                        opacity: materialPolicy.opacity,
                        tintColor: materialPolicy.tintColor,
                        cornerRadius: materialPolicy.cornerRadius,
                        preferLiquidGlass: materialPolicy.preferLiquidGlass
                    )
                }
                if !materialPolicy.usesWindowLevelGlass && !usingNativeLiquidGlass {
                    Color(nsColor: materialPolicy.tintColor)
                }
            }
        case .clear:
            Color.clear
        }
    }
}
