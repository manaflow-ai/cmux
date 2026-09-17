public import Foundation

/// Daemon-retained navigation state for one stable logical Swift window.
public struct BackendProjectionNavigationState: Codable, Equatable, Sendable {
    /// The projection schema version, currently `2`.
    public let schemaVersion: UInt8

    /// The stable logical Swift-window identifier.
    public let logicalPresentationID: UUID

    /// The optimistic-concurrency generation for this record.
    public let generation: UInt64

    /// The connection-owned mutation claim, visible only to its owner.
    public let claimID: UUID?

    /// The process instance holding ``claimID``, when claimed.
    public let claimedProcessInstanceID: UUID?

    /// The canonical topology revision against which this state was reconciled.
    public let reconciledTopologyRevision: UInt64

    /// The assigned workspace currently selected by this logical window.
    public let selectedWorkspaceID: WorkspaceID?

    /// Assigned workspaces and their preferences in canonical order.
    public let workspaces: [BackendProjectionNavigationWorkspaceState]

    /// Creates one complete projection-navigation record.
    ///
    /// - Parameters:
    ///   - schemaVersion: The projection schema version.
    ///   - logicalPresentationID: The stable logical-window identifier.
    ///   - generation: The record generation.
    ///   - claimID: The connection-owned mutation claim.
    ///   - claimedProcessInstanceID: The process holding the claim.
    ///   - reconciledTopologyRevision: The reconciled topology revision.
    ///   - selectedWorkspaceID: The selected assigned workspace.
    ///   - workspaces: Assigned workspace preferences in canonical order.
    public init(
        schemaVersion: UInt8 = 2,
        logicalPresentationID: UUID,
        generation: UInt64,
        claimID: UUID?,
        claimedProcessInstanceID: UUID?,
        reconciledTopologyRevision: UInt64,
        selectedWorkspaceID: WorkspaceID?,
        workspaces: [BackendProjectionNavigationWorkspaceState]
    ) {
        self.schemaVersion = schemaVersion
        self.logicalPresentationID = logicalPresentationID
        self.generation = generation
        self.claimID = claimID
        self.claimedProcessInstanceID = claimedProcessInstanceID
        self.reconciledTopologyRevision = reconciledTopologyRevision
        self.selectedWorkspaceID = selectedWorkspaceID
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case logicalPresentationID = "logical_presentation_id"
        case generation
        case claimID = "claim_id"
        case claimedProcessInstanceID = "claimed_process_instance_uuid"
        case reconciledTopologyRevision = "reconciled_topology_revision"
        case selectedWorkspaceID = "selected_workspace_uuid"
        case workspaces
    }
}
