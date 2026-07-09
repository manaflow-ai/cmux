public import Foundation

/// A single closed-panel-history workspace-id remap to apply after a restore.
///
/// Restore replaces a workspace's pre-restore UUID with a freshly minted one,
/// so any closed-panel history recorded under the old workspace id must be
/// rewritten to the new id (and its panel ids translated through `panelIdMap`)
/// or the "recently closed panels" list points at a dead workspace. This value
/// describes one such rewrite; ``ClosedPanelHistoryRemapPlanner`` produces the
/// ordered list, and the app shell applies each entry to its closed-item
/// history store.
public struct ClosedPanelHistoryRemapOperation: Sendable, Equatable {
    /// The pre-restore workspace id history was recorded under.
    public let fromWorkspaceId: UUID
    /// The post-restore workspace id history should move to.
    public let toWorkspaceId: UUID
    /// Old-to-new panel id translations for the moved records.
    public let panelIdMap: [UUID: UUID]

    /// Creates a remap operation.
    public init(fromWorkspaceId: UUID, toWorkspaceId: UUID, panelIdMap: [UUID: UUID]) {
        self.fromWorkspaceId = fromWorkspaceId
        self.toWorkspaceId = toWorkspaceId
        self.panelIdMap = panelIdMap
    }
}
