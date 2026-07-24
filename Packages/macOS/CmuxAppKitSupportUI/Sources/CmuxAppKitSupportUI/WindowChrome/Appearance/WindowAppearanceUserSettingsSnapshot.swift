public import SwiftUI

/// User settings needed to resolve window appearance.
public struct WindowAppearanceUserSettingsSnapshot {
    /// Whether sidebars share the terminal root backdrop.
    public let unifySurfaceBackdrops: Bool

    /// Color scheme selected for sidebar tint resolution.
    public let colorScheme: ColorScheme

    /// Raw `sidebarMaterial` value.
    public let sidebarMaterial: String

    /// Raw `sidebarBlendMode` value.
    public let sidebarBlendMode: String

    /// Raw `sidebarState` value.
    public let sidebarState: String

    /// Base sidebar tint hex.
    public let sidebarTintHex: String

    /// Light-mode sidebar tint override.
    public let sidebarTintHexLight: String?

    /// Dark-mode sidebar tint override.
    public let sidebarTintHexDark: String?

    /// Sidebar tint opacity.
    public let sidebarTintOpacity: Double

    /// Sidebar corner radius.
    public let sidebarCornerRadius: Double

    /// Sidebar blur opacity.
    public let sidebarBlurOpacity: Double

    /// Whether background glass is enabled.
    public let bgGlassEnabled: Bool

    /// Background glass tint hex.
    public let bgGlassTintHex: String

    /// Background glass tint opacity.
    public let bgGlassTintOpacity: Double

    /// Creates a user settings snapshot for window appearance.
    public init(
        unifySurfaceBackdrops: Bool,
        colorScheme: ColorScheme,
        sidebarMaterial: String,
        sidebarBlendMode: String,
        sidebarState: String,
        sidebarTintHex: String,
        sidebarTintHexLight: String?,
        sidebarTintHexDark: String?,
        sidebarTintOpacity: Double,
        sidebarCornerRadius: Double,
        sidebarBlurOpacity: Double,
        bgGlassEnabled: Bool,
        bgGlassTintHex: String,
        bgGlassTintOpacity: Double
    ) {
        self.unifySurfaceBackdrops = unifySurfaceBackdrops
        self.colorScheme = colorScheme
        self.sidebarMaterial = sidebarMaterial
        self.sidebarBlendMode = sidebarBlendMode
        self.sidebarState = sidebarState
        self.sidebarTintHex = sidebarTintHex
        self.sidebarTintHexLight = sidebarTintHexLight
        self.sidebarTintHexDark = sidebarTintHexDark
        self.sidebarTintOpacity = sidebarTintOpacity
        self.sidebarCornerRadius = sidebarCornerRadius
        self.sidebarBlurOpacity = sidebarBlurOpacity
        self.bgGlassEnabled = bgGlassEnabled
        self.bgGlassTintHex = bgGlassTintHex
        self.bgGlassTintOpacity = bgGlassTintOpacity
    }
}
