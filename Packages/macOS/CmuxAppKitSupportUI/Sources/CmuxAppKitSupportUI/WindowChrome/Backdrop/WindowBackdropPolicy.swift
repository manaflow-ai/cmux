public import AppKit
import CmuxFoundation

/// Backdrop rendering policy for one chrome surface.
public enum WindowBackdropPolicy {
    /// A terminal-colored backdrop with the resolved opacity and renderer owner.
    case ghosttyTerminalBackdrop(
        color: NSColor,
        opacity: CGFloat,
        renderingMode: GhosttyTerminalBackdropRenderingMode
    )

    /// A sidebar AppKit material or tint policy.
    case sidebarMaterial(SidebarBackdropMaterialPolicy)

    /// A fully clear surface.
    case clear

    /// The host-layer color to apply for this policy, when one is needed.
    public var hostLayerBackgroundColor: NSColor? {
        switch self {
        case let .ghosttyTerminalBackdrop(color, opacity, renderingMode):
            guard renderingMode.usesWindowHostBackdrop else { return nil }
            return color.withAlphaComponent(opacity)
        case .sidebarMaterial, .clear:
            return nil
        }
    }

    var identityComponent: String {
        switch self {
        case let .ghosttyTerminalBackdrop(color, opacity, renderingMode):
            return [
                "ghosttyTerminalBackdrop",
                color.hexString(includeAlpha: true),
                String(format: "%.4f", Double(opacity)),
                String(describing: renderingMode),
            ].joined(separator: ":")
        case let .sidebarMaterial(materialPolicy):
            return [
                "sidebarMaterial",
                String(describing: materialPolicy.material),
                String(describing: materialPolicy.blendingMode),
                String(describing: materialPolicy.state),
                String(format: "%.4f", materialPolicy.opacity),
                materialPolicy.tintColor.hexString(includeAlpha: true),
                String(format: "%.4f", Double(materialPolicy.cornerRadius)),
                String(materialPolicy.preferLiquidGlass),
                String(materialPolicy.usesWindowLevelGlass),
            ].joined(separator: ":")
        case .clear:
            return "clear"
        }
    }
}
