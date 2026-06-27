public import Foundation

/// The identity of a single panel within a workspace, keyed by the owning
/// workspace's id and the panel's id.
///
/// A pure `Hashable`, `Sendable` value used as the dictionary key for the
/// per-panel restorable-agent and surface-resume-binding indexes (the app's
/// `RestorableAgentSessionIndex` / `SurfaceResumeBindingIndex` keep a
/// `typealias PanelKey = WorkspacePanelKey`). Holds no behavior; equality is
/// the pair `(workspaceId, panelId)`.
public struct WorkspacePanelKey: Hashable, Sendable {
    /// The id of the workspace that owns the panel.
    public let workspaceId: UUID
    /// The id of the panel within that workspace.
    public let panelId: UUID

    /// Creates a key for the panel `panelId` inside workspace `workspaceId`.
    public init(workspaceId: UUID, panelId: UUID) {
        self.workspaceId = workspaceId
        self.panelId = panelId
    }
}
