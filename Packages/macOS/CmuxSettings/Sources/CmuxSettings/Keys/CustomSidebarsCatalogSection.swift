import Foundation

/// Settings for custom (user/agent-authored) sidebars, the `customSidebars.*`
/// keys. The beta gate that lists custom sidebars in the picker lives in
/// ``BetaFeaturesCatalogSection/customSidebars``; this section holds how a
/// selected custom sidebar behaves.
public struct CustomSidebarsCatalogSection: SettingCatalogSection {
    /// Which renderer a selected custom sidebar uses: `inProcess` (default;
    /// native in-host SwiftUI with real hover/focus/keyboard) or `remote`
    /// (the crash-isolated out-of-process worker for untrusted sources).
    ///
    /// JSON-backed so it can be flipped by editing `~/.config/cmux/cmux.json`:
    ///
    /// ```json
    /// { "customSidebars": { "renderer": "remote" } }
    /// ```
    public let renderer = JSONKey<CustomSidebarRendererMode>(
        id: "customSidebars.renderer",
        defaultValue: .inProcess
    )

    public init() {}
}
