public import AppKit

/// Resolved AppKit material settings for a sidebar backdrop.
public struct SidebarBackdropMaterialPolicy {
    /// AppKit material to use, or `nil` for tint-only rendering.
    public let material: NSVisualEffectView.Material?

    /// AppKit blending mode for the material.
    public let blendingMode: NSVisualEffectView.BlendingMode

    /// AppKit active/inactive state for the material.
    public let state: NSVisualEffectView.State

    /// Opacity applied to the material view.
    public let opacity: Double

    /// Tint color applied above the material or into native glass.
    public let tintColor: NSColor

    /// Corner radius applied to the material view.
    public let cornerRadius: CGFloat

    /// Whether native `NSGlassEffectView` should be preferred.
    public let preferLiquidGlass: Bool

    /// Whether the material is supplied by the window-level glass root.
    public let usesWindowLevelGlass: Bool

    /// Appearance to force on the material view so the native `.sidebar`
    /// material matches the app color scheme instead of the window's
    /// NSAppearance (which may still be dark in Light mode). `nil` inherits.
    public let appearanceName: NSAppearance.Name?

    /// Creates resolved material settings for a sidebar backdrop.
    public init(
        material: NSVisualEffectView.Material?,
        blendingMode: NSVisualEffectView.BlendingMode,
        state: NSVisualEffectView.State,
        opacity: Double,
        tintColor: NSColor,
        cornerRadius: CGFloat,
        preferLiquidGlass: Bool,
        usesWindowLevelGlass: Bool,
        appearanceName: NSAppearance.Name? = nil
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.opacity = opacity
        self.tintColor = tintColor
        self.cornerRadius = cornerRadius
        self.preferLiquidGlass = preferLiquidGlass
        self.usesWindowLevelGlass = usesWindowLevelGlass
        self.appearanceName = appearanceName
    }
}
