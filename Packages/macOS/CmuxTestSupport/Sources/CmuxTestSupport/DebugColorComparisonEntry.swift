#if DEBUG
/// One named color the Debug-menu "color comparison workspaces" opener renders
/// as a titled, colored workspace.
///
/// `AppDelegate.openDebugColorComparisonWorkspaces(_:)` walks the workspace
/// tab-color palette and creates (or reuses) one workspace per color, titled
/// `"Debug Color - <name>"` and tinted with `<hex>`.
/// ``DebugTerminalActionsCoordinator`` owns that create-or-reuse loop; the app
/// target supplies these entries by projecting its `WorkspaceTabColorEntry`
/// palette (an app type that cannot cross the package boundary) onto this
/// value. `name` and `hex` carry the same strings the legacy loop read off each
/// palette entry.
public struct DebugColorComparisonEntry: Sendable, Equatable {
    /// The color's display name, used to build the workspace title.
    public let name: String

    /// The color's hex string (e.g. `"#C0392B"`), applied as the tab color.
    public let hex: String

    /// Creates an entry from a palette color's `name` and `hex`.
    public init(name: String, hex: String) {
        self.name = name
        self.hex = hex
    }
}
#endif
