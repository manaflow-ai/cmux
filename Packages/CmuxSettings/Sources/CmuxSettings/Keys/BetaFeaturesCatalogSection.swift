import Foundation

/// Beta-feature toggles. Each key here gates an experimental code path
/// in the running app. The id prefix is `rightSidebar.beta.*` for the
/// existing right-sidebar Dock toggle; new betas should follow the
/// pattern `<feature-domain>.beta.<flag-name>` so the cmux.json view
/// groups them sensibly.
public struct BetaFeaturesCatalogSection: SettingCatalogSection {
    /// Right-sidebar Feed: an experimental mode that surfaces inline agent
    /// decisions (permission prompts, questions) in the right-sidebar mode
    /// switcher. Defaults off; while off, the Feed mode is hidden from the
    /// switcher so the feature stays opt-in while it is in beta.
    public let rightSidebarFeed = DefaultsKey<Bool>(
        id: "rightSidebar.beta.feed.enabled",
        defaultValue: false,
        userDefaultsKey: "rightSidebar.beta.feed.enabled"
    )

    /// Right-sidebar Dock: an experimental terminal-controls dock that
    /// replaces the per-pane action chrome with a unified right-side
    /// rail. Defaults off; flagged as unstable in the Settings UI.
    public let rightSidebarDock = DefaultsKey<Bool>(
        id: "rightSidebar.beta.dock.enabled",
        defaultValue: false,
        userDefaultsKey: "rightSidebar.beta.dock.enabled"
    )

    /// Extensions: the experimental ExtensionKit sidebar-extension surface
    /// (puzzle button, sidebar-toggle provider menu, installed-extension
    /// host, and the extensions browser). Defaults off; while off, every
    /// extension-related entry point is hidden so the feature stays opt-in
    /// while it is in beta.
    public let extensions = DefaultsKey<Bool>(
        id: "extensions.beta.enabled",
        defaultValue: false,
        userDefaultsKey: "extensions.beta.enabled"
    )

    /// Custom sidebars: user/agent-authored sidebars (interpreted Swift or
    /// JSON) discovered from `~/.config/cmux/sidebars/` and selectable in the
    /// sidebar button's provider picker. Defaults off; while off, no custom
    /// sidebar appears in the picker and a persisted custom selection falls
    /// back to the default workspaces sidebar.
    public let customSidebars = DefaultsKey<Bool>(
        id: "customSidebars.beta.enabled",
        defaultValue: false,
        userDefaultsKey: "customSidebars.beta.enabled"
    )

    public init() {}
}
