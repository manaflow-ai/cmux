public import Foundation

/// The explicit workspace+panel scope shell integration passes to the v1
/// sidebar telemetry commands (`--tab=<uuid> --panel=<uuid>`), the typed twin
/// of the legacy `explicitSocketScope` tuple.
public struct ControlSidebarPanelScope: Sendable, Equatable {
    /// The workspace (tab) id.
    public let workspaceID: UUID
    /// The panel (surface) id.
    public let panelID: UUID

    /// Creates a scope.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace (tab) id.
    ///   - panelID: The panel (surface) id.
    public init(workspaceID: UUID, panelID: UUID) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }
}
