import Foundation

/// Beta-feature toggles. Each key here gates an experimental code path
/// in the running app. The id prefix is `rightSidebar.beta.*` for the
/// existing right-sidebar Dock toggle; new betas should follow the
/// pattern `<feature-domain>.beta.<flag-name>` so the cmux.json view
/// groups them sensibly.
public struct BetaFeaturesCatalogSection: SettingCatalogSection {
    /// Right-sidebar Dock: an experimental terminal-controls dock that
    /// replaces the per-pane action chrome with a unified right-side
    /// rail. Defaults off; flagged as unstable in the Settings UI.
    public let rightSidebarDock = DefaultsKey<Bool>(
        id: "rightSidebar.beta.dock.enabled",
        defaultValue: false,
        userDefaultsKey: "rightSidebar.beta.dock.enabled"
    )

    /// Sidebar extensions: an experimental left-sidebar provider system
    /// that lets a custom ExtensionKit extension replace the default
    /// workspace list. Defaults off; flagged as unstable in the Settings
    /// UI. When off, the sidebar always renders the default workspace list.
    public let sidebarExtensions = DefaultsKey<Bool>(
        id: "sidebar.beta.extensions.enabled",
        defaultValue: false,
        userDefaultsKey: "sidebar.beta.extensions.enabled"
    )

    public init() {}
}
