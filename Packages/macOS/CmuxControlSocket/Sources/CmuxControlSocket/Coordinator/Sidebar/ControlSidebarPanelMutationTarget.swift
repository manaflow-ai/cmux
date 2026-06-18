public import Foundation

/// The pre-parsed target of a v1 panel-metadata mutation (`report_pr` /
/// `clear_pr` / `report_pr_action`): either the explicit shell-integration
/// scope, or the legacy report-tab fallback (`--tab` option value plus an
/// optional explicit panel id, focused panel otherwise).
public struct ControlSidebarPanelMutationTarget: Sendable, Equatable {
    /// The explicit workspace+panel scope, when both `--tab` and `--panel`
    /// are UUIDs (takes the off-main fast path).
    public let scope: ControlSidebarPanelScope?
    /// The raw `--tab` option value for the fallback resolution path.
    public let tabArg: String?
    /// The explicit panel id for the fallback path (`nil` = focused panel).
    public let panelID: UUID?

    /// Creates a target.
    ///
    /// - Parameters:
    ///   - scope: The explicit workspace+panel scope, if any.
    ///   - tabArg: The raw `--tab` option value for the fallback path.
    ///   - panelID: The explicit panel id for the fallback path.
    public init(scope: ControlSidebarPanelScope?, tabArg: String?, panelID: UUID?) {
        self.scope = scope
        self.tabArg = tabArg
        self.panelID = panelID
    }
}
