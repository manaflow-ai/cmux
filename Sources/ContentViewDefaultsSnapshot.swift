import CmuxAppKitSupportUI
import CmuxSettings
import Foundation

/// Values from `UserDefaults` that the window composition root renders.
///
/// Comparing this projection keeps unrelated defaults writes from
/// invalidating every mounted terminal and sidebar in the window.
struct ContentViewDefaultsSnapshot: Equatable, Sendable {
    let titlebarControlsStyleRawValue: Int
    let rightSidebarMaxWidthSetting: Double
    let sidebarMinimumWidthSetting: Double
    let titlebarLeftControlsLeadingInset: Double
    let titlebarLeftControlsTopInset: Double
    let titlebarTrafficLightTabBarInset: Double
    let titlebarTrafficLightTitlebarLeadingInset: Double
    let activePaneBorderColorHex: String
    let selectedSidebarProviderId: String
    let commandPaletteRenameSelectAllOnFocus: Bool
    let commandPaletteSearchAllSurfaces: Bool
    let appearanceMode: String
    let sidebarBlendMode: String
    let sidebarMatchTerminalBackground: Bool
    let sidebarTintOpacity: Double
    let sidebarTintHex: String
    let sidebarTintHexLight: String?
    let sidebarTintHexDark: String?
    let sidebarMaterial: String
    let sidebarStateSetting: String
    let sidebarCornerRadius: Double
    let sidebarBlurOpacity: Double
    let bgGlassTintHex: String
    let bgGlassTintOpacity: Double
    let bgGlassEnabled: Bool

    init(defaults: UserDefaults) {
        let app = AppCatalogSection()
        let tintDefaults = SidebarTintDefaults()
        titlebarControlsStyleRawValue = TitlebarControlsStyle.stored(in: defaults).rawValue
        rightSidebarMaxWidthSetting = Self.double(
            defaults,
            key: RightSidebarWidthSettings.maxWidthKey,
            defaultValue: RightSidebarWidthSettings.noOverrideValue
        )
        sidebarMinimumWidthSetting = Self.double(
            defaults,
            key: SessionPersistencePolicy.sidebarMinimumWidthKey,
            defaultValue: SessionPersistencePolicy.defaultMinimumSidebarWidth
        )
        titlebarLeftControlsLeadingInset = Self.double(
            defaults,
            key: MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey,
            defaultValue: MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
        )
        titlebarLeftControlsTopInset = Self.double(
            defaults,
            key: MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey,
            defaultValue: MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset
        )
        titlebarTrafficLightTabBarInset = Self.double(
            defaults,
            key: MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey,
            defaultValue: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset
        )
        titlebarTrafficLightTitlebarLeadingInset = Self.double(
            defaults,
            key: MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey,
            defaultValue: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
        )
        activePaneBorderColorHex = defaults.string(forKey: PaneChromeSettings.activePaneBorderColorKey)
            ?? PaneChromeSettings.defaultColorHex
        selectedSidebarProviderId = defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
            ?? CmuxExtensionSidebarSelection.defaultProviderId
        commandPaletteRenameSelectAllOnFocus = Self.bool(
            defaults,
            key: app.renameSelectsExistingName.userDefaultsKey,
            defaultValue: app.renameSelectsExistingName.defaultValue
        )
        commandPaletteSearchAllSurfaces = Self.bool(
            defaults,
            key: app.commandPaletteSearchesAllSurfaces.userDefaultsKey,
            defaultValue: app.commandPaletteSearchesAllSurfaces.defaultValue
        )
        appearanceMode = defaults.string(forKey: AppearanceSettings.appearanceModeKey)
            ?? AppearanceSettings.defaultMode.rawValue
        sidebarBlendMode = defaults.string(forKey: "sidebarBlendMode")
            ?? SidebarBlendModeOption.withinWindow.rawValue
        sidebarMatchTerminalBackground = Self.bool(
            defaults,
            key: "sidebarMatchTerminalBackground",
            defaultValue: false
        )
        sidebarTintOpacity = Self.double(
            defaults,
            key: "sidebarTintOpacity",
            defaultValue: tintDefaults.opacity
        )
        sidebarTintHex = defaults.string(forKey: "sidebarTintHex") ?? tintDefaults.hex
        sidebarTintHexLight = defaults.string(forKey: "sidebarTintHexLight")
        sidebarTintHexDark = defaults.string(forKey: "sidebarTintHexDark")
        sidebarMaterial = defaults.string(forKey: "sidebarMaterial")
            ?? SidebarMaterialOption.sidebar.rawValue
        sidebarStateSetting = defaults.string(forKey: "sidebarState")
            ?? SidebarStateOption.followWindow.rawValue
        sidebarCornerRadius = Self.double(defaults, key: "sidebarCornerRadius", defaultValue: 0)
        sidebarBlurOpacity = Self.double(defaults, key: "sidebarBlurOpacity", defaultValue: 1)
        bgGlassTintHex = defaults.string(forKey: "bgGlassTintHex") ?? "#000000"
        bgGlassTintOpacity = Self.double(defaults, key: "bgGlassTintOpacity", defaultValue: 0.03)
        bgGlassEnabled = Self.bool(defaults, key: "bgGlassEnabled", defaultValue: false)
    }

    private static func bool(
        _ defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func double(
        _ defaults: UserDefaults,
        key: String,
        defaultValue: Double
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.double(forKey: key)
    }
}
