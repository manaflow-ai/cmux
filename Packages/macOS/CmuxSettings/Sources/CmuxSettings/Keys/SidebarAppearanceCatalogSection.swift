import Foundation

/// Settings under the dotted-id prefix `sidebarAppearance.*`.
public struct SidebarAppearanceCatalogSection: SettingCatalogSection {
    public let matchTerminalBackground = DefaultsKey<Bool>(
        id: "sidebarAppearance.matchTerminalBackground",
        defaultValue: false,
        userDefaultsKey: "sidebarMatchTerminalBackground"
    )

    public let tintColorHex = DefaultsKey<String>(
        id: "sidebarAppearance.tintColor",
        defaultValue: "#393939",
        userDefaultsKey: "sidebarTintHex"
    )

    public let lightModeTintColorHex = DefaultsKey<String>(
        id: "sidebarAppearance.lightModeTintColor",
        defaultValue: "",
        userDefaultsKey: "sidebarTintHexLight"
    )

    public let darkModeTintColorHex = DefaultsKey<String>(
        id: "sidebarAppearance.darkModeTintColor",
        defaultValue: "",
        userDefaultsKey: "sidebarTintHexDark"
    )

    public let tintOpacity = DefaultsKey<Double>(
        id: "sidebarAppearance.tintOpacity",
        defaultValue: 0.72,
        userDefaultsKey: "sidebarTintOpacity"
    )

    public let blurOpacity = DefaultsKey<Double>(
        id: "sidebarAppearance.blurOpacity",
        defaultValue: 1.0,
        userDefaultsKey: "sidebarBlurOpacity"
    )

    public let compositorGlass = DefaultsKey<Bool>(
        id: "sidebarAppearance.compositorGlass",
        defaultValue: true,
        userDefaultsKey: "sidebarCompositorGlass"
    )

    public let glassBlurRadius = DefaultsKey<Double>(
        id: "sidebarAppearance.glassBlurRadius",
        defaultValue: Self.glassBlurRadiusRange.lowerBound,
        userDefaultsKey: "sidebarGlassBlurRadius"
    )

    /// Compositor blur radius bounds in points. The floor keeps the sidebar
    /// reading as glass (a crisp pane is not the look); the ceiling is where
    /// blur stops reading as glass and just smears. Mirrored by the clamp in
    /// `SidebarBackdropSettingsSnapshot`, which cannot import this module.
    public static let glassBlurRadiusRange: ClosedRange<Double> = 12...60

    public let cornerRadius = DefaultsKey<Double>(
        id: "sidebarAppearance.cornerRadius",
        defaultValue: 0.0,
        userDefaultsKey: "sidebarCornerRadius"
    )

    public let preset = DefaultsKey<SidebarPresetOption>(
        id: "sidebarAppearance.preset",
        defaultValue: .nativeSidebar,
        userDefaultsKey: "sidebarPreset"
    )

    public let material = DefaultsKey<SidebarMaterialOption>(
        id: "sidebarAppearance.material",
        defaultValue: .hudWindow,
        userDefaultsKey: "sidebarMaterial"
    )

    public let blendMode = DefaultsKey<SidebarBlendModeOption>(
        id: "sidebarAppearance.blendMode",
        defaultValue: .behindWindow,
        userDefaultsKey: "sidebarBlendMode"
    )

    public let state = DefaultsKey<SidebarStateOption>(
        id: "sidebarAppearance.state",
        defaultValue: .active,
        userDefaultsKey: "sidebarState"
    )

    public init() {}
}
