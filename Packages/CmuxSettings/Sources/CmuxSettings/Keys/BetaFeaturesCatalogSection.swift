import Foundation

/// Beta-feature toggles. Each key here gates an experimental code path
/// in the running app. The id prefix is `rightSidebar.beta.*` for the
/// existing right-sidebar Dock toggle; new betas should follow the
/// pattern `<feature-domain>.beta.<flag-name>` so the cmux.json view
/// groups them sensibly.
public struct BetaFeaturesCatalogSection: SettingCatalogSection {
    /// Dock: the multi-dock workspace layout. Each window edge (bottom and
    /// right by default, left when ``leftDock`` is on) gets its own dock
    /// with an independent split tree, toggled from the workspace
    /// titlebar. Defaults off; flagged as unstable in the Settings UI.
    public let dock = DefaultsKey<Bool>(
        id: "docks.enabled",
        defaultValue: false,
        userDefaultsKey: "docks.enabled"
    )

    /// Left dock: when ``dock`` is enabled, also show the left dock toggle
    /// in the workspace titlebar (bottom and right show by default).
    /// Defaults off.
    public let leftDock = DefaultsKey<Bool>(
        id: "docks.leftEnabled",
        defaultValue: false,
        userDefaultsKey: "docks.leftEnabled"
    )

    public init() {}
}
