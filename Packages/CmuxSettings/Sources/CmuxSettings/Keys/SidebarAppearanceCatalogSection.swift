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
        defaultValue: "#000000",
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
        defaultValue: 0.18,
        userDefaultsKey: "sidebarTintOpacity"
    )

    public let blurOpacity = DefaultsKey<Double>(
        id: "sidebarAppearance.blurOpacity",
        defaultValue: 1.0,
        userDefaultsKey: "sidebarBlurOpacity"
    )

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
        defaultValue: .sidebar,
        userDefaultsKey: "sidebarMaterial"
    )

    public let blendMode = DefaultsKey<SidebarBlendModeOption>(
        id: "sidebarAppearance.blendMode",
        defaultValue: .withinWindow,
        userDefaultsKey: "sidebarBlendMode"
    )

    public let state = DefaultsKey<SidebarStateOption>(
        id: "sidebarAppearance.state",
        defaultValue: .followWindow,
        userDefaultsKey: "sidebarState"
    )

    /// Path to the full-window background image (empty disables it). A leading
    /// `~` is expanded. Type `String`, default `""`, persisted under
    /// `sidebarBackgroundImagePath`.
    public let backgroundImagePath = DefaultsKey<String>(
        id: "sidebarAppearance.backgroundImage",
        defaultValue: "",
        userDefaultsKey: "sidebarBackgroundImagePath"
    )

    /// Opacity of the full-window background image, range `0...1`. Type
    /// `Double`, default `0.2`, persisted under `sidebarBackgroundImageOpacity`.
    public let backgroundImageOpacity = DefaultsKey<Double>(
        id: "sidebarAppearance.backgroundImageOpacity",
        defaultValue: 0.2,
        userDefaultsKey: "sidebarBackgroundImageOpacity"
    )

    /// How the background image scales to fill the window: `"cover"` or
    /// `"contain"`. Type `String`, default `"cover"`, persisted under
    /// `sidebarBackgroundImageFit`.
    public let backgroundImageFit = DefaultsKey<String>(
        id: "sidebarAppearance.backgroundImageFit",
        defaultValue: "cover",
        userDefaultsKey: "sidebarBackgroundImageFit"
    )

    public init() {}
}
