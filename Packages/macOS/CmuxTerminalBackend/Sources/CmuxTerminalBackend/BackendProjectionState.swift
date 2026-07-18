public import Foundation

/// One canonical workspace and selected screen retained for a logical Swift window.
public struct BackendProjectionWorkspaceState: Codable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let selectedScreenID: ScreenID

    public init(workspaceID: WorkspaceID, selectedScreenID: ScreenID) {
        self.workspaceID = workspaceID
        self.selectedScreenID = selectedScreenID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_uuid"
        case selectedScreenID = "selected_screen_uuid"
    }
}

/// Daemon-lifetime placement state for one stable logical Swift window.
///
/// `claimID` is returned only to the connection that currently owns the
/// mutation fence. This state never represents renderer visibility or a PTY
/// mutation lease.
public struct BackendProjectionState: Codable, Equatable, Sendable {
    public let logicalPresentationID: UUID
    public let generation: UInt64
    public let claimID: UUID?
    public let claimedProcessInstanceID: UUID?
    public let workspaces: [BackendProjectionWorkspaceState]

    public init(
        logicalPresentationID: UUID,
        generation: UInt64,
        claimID: UUID?,
        claimedProcessInstanceID: UUID?,
        workspaces: [BackendProjectionWorkspaceState]
    ) {
        self.logicalPresentationID = logicalPresentationID
        self.generation = generation
        self.claimID = claimID
        self.claimedProcessInstanceID = claimedProcessInstanceID
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey {
        case logicalPresentationID = "logical_presentation_id"
        case generation
        case claimID = "claim_id"
        case claimedProcessInstanceID = "claimed_process_instance_uuid"
        case workspaces
    }
}

/// One member of an atomic multi-window projection-state replacement.
public struct BackendProjectionStateUpdate: Equatable, Sendable {
    public let logicalPresentationID: UUID
    public let claimID: UUID
    public let expectedGeneration: UInt64
    public let workspaces: [BackendProjectionWorkspaceState]

    public init(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64,
        workspaces: [BackendProjectionWorkspaceState]
    ) {
        self.logicalPresentationID = logicalPresentationID
        self.claimID = claimID
        self.expectedGeneration = expectedGeneration
        self.workspaces = workspaces
    }
}

extension BackendProtocolClient {
    /// Claims or reclaims one daemon-retained logical Swift window.
    public func claimProjectionState(
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState {
        try await call(
            command: "claim-projection-state",
            parameters: [
                "logical_presentation_id": .string(logicalPresentationID.uuidString.lowercased()),
            ],
            as: BackendProjectionState.self
        )
    }

    /// Atomically replaces one claimed window's complete workspace mapping.
    public func updateProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64,
        workspaces: [BackendProjectionWorkspaceState]
    ) async throws -> BackendProjectionState {
        try await call(
            command: "update-projection-state",
            parameters: [
                "logical_presentation_id": .string(logicalPresentationID.uuidString.lowercased()),
                "claim_id": .string(claimID.uuidString.lowercased()),
                "expected_generation": .unsignedInteger(expectedGeneration),
                "workspaces": .array(workspaces.map(\.jsonValue)),
            ],
            as: BackendProjectionState.self
        )
    }

    /// Atomically replaces several claimed logical windows.
    public func updateProjectionStates(
        _ projections: [BackendProjectionStateUpdate]
    ) async throws -> [BackendProjectionState] {
        try await call(
            command: "update-projection-states",
            parameters: [
                "projections": .array(projections.map(\.jsonValue)),
            ],
            as: [BackendProjectionState].self
        )
    }

    /// Explicitly deletes a closed logical Swift window's retained mapping.
    public func releaseProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64
    ) async throws {
        let _: BackendEmptyResponse = try await call(
            command: "release-projection-state",
            parameters: [
                "logical_presentation_id": .string(logicalPresentationID.uuidString.lowercased()),
                "claim_id": .string(claimID.uuidString.lowercased()),
                "expected_generation": .unsignedInteger(expectedGeneration),
            ],
            as: BackendEmptyResponse.self
        )
    }

    /// Lists daemon-retained logical windows for the registered stable client.
    public func listProjectionStates() async throws -> [BackendProjectionState] {
        try await call(command: "list-projection-states", as: [BackendProjectionState].self)
    }
}

private extension BackendProjectionWorkspaceState {
    var jsonValue: BackendJSONValue {
        .object([
            "workspace_uuid": .string(workspaceID.description),
            "selected_screen_uuid": .string(selectedScreenID.description),
        ])
    }
}

private extension BackendProjectionStateUpdate {
    var jsonValue: BackendJSONValue {
        .object([
            "logical_presentation_id": .string(
                logicalPresentationID.uuidString.lowercased()
            ),
            "claim_id": .string(claimID.uuidString.lowercased()),
            "expected_generation": .unsignedInteger(expectedGeneration),
            "workspaces": .array(workspaces.map(\.jsonValue)),
        ])
    }
}
