public import Foundation

/// Health of the daemon's durable canonical state at handoff preparation.
public enum BackendServiceDurableStorageState: String, Codable, Equatable, Sendable {
    case disabled
    case healthy
    case degraded
}

/// Content-free durable-storage evidence bound into a handoff permit.
public struct BackendServiceDurableStorageStatus: Codable, Equatable, Sendable {
    public let state: BackendServiceDurableStorageState
    public let incidentID: UUID?
    public let failurePhase: String?
    public let failureResolution: String?
    public let unresolvedMutation: Bool
    public let unresolvedLaunchAttempts: UInt64

    public init(
        state: BackendServiceDurableStorageState,
        incidentID: UUID?,
        failurePhase: String?,
        failureResolution: String?,
        unresolvedMutation: Bool,
        unresolvedLaunchAttempts: UInt64
    ) {
        self.state = state
        self.incidentID = incidentID
        self.failurePhase = failurePhase
        self.failureResolution = failureResolution
        self.unresolvedMutation = unresolvedMutation
        self.unresolvedLaunchAttempts = unresolvedLaunchAttempts
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case incidentID = "incident_id"
        case failurePhase = "failure_phase"
        case failureResolution = "failure_resolution"
        case unresolvedMutation = "unresolved_mutation"
        case unresolvedLaunchAttempts = "unresolved_launch_attempts"
    }
}

/// Content-free daemon-lifetime state that would be lost by replacement.
public struct BackendServiceHandoffBlockers: Codable, Equatable, Sendable {
    public let canonicalSurfaces: UInt64
    public let pendingTerminalLaunches: UInt64
    public let presentations: UInt64
    public let projectionStates: UInt64
    public let terminalAuthorities: UInt64
    public let rendererPresentations: UInt64
    public let rendererWorkers: UInt64
    public let pendingRendererRemovals: UInt64
    public let rendererReleaseRoutes: UInt64
    public let browserRuntime: Bool
    public let frontendNativeBrowserRuntimes: UInt64
    public let remoteExternalProducerRuntimes: UInt64
    public let sidebarPluginRuntime: Bool
    public let agentRecords: UInt64
    public let unresolvedDurableMutation: Bool
    public let unresolvedLaunchAttempts: UInt64
    public let durableStorageDegraded: Bool

    public init(
        canonicalSurfaces: UInt64,
        pendingTerminalLaunches: UInt64,
        presentations: UInt64,
        projectionStates: UInt64,
        terminalAuthorities: UInt64,
        rendererPresentations: UInt64,
        rendererWorkers: UInt64,
        pendingRendererRemovals: UInt64,
        rendererReleaseRoutes: UInt64,
        browserRuntime: Bool,
        frontendNativeBrowserRuntimes: UInt64,
        remoteExternalProducerRuntimes: UInt64,
        sidebarPluginRuntime: Bool,
        agentRecords: UInt64,
        unresolvedDurableMutation: Bool,
        unresolvedLaunchAttempts: UInt64,
        durableStorageDegraded: Bool
    ) {
        self.canonicalSurfaces = canonicalSurfaces
        self.pendingTerminalLaunches = pendingTerminalLaunches
        self.presentations = presentations
        self.projectionStates = projectionStates
        self.terminalAuthorities = terminalAuthorities
        self.rendererPresentations = rendererPresentations
        self.rendererWorkers = rendererWorkers
        self.pendingRendererRemovals = pendingRendererRemovals
        self.rendererReleaseRoutes = rendererReleaseRoutes
        self.browserRuntime = browserRuntime
        self.frontendNativeBrowserRuntimes = frontendNativeBrowserRuntimes
        self.remoteExternalProducerRuntimes = remoteExternalProducerRuntimes
        self.sidebarPluginRuntime = sidebarPluginRuntime
        self.agentRecords = agentRecords
        self.unresolvedDurableMutation = unresolvedDurableMutation
        self.unresolvedLaunchAttempts = unresolvedLaunchAttempts
        self.durableStorageDegraded = durableStorageDegraded
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalSurfaces = "canonical_surfaces"
        case pendingTerminalLaunches = "pending_terminal_launches"
        case presentations
        case projectionStates = "projection_states"
        case terminalAuthorities = "terminal_authorities"
        case rendererPresentations = "renderer_presentations"
        case rendererWorkers = "renderer_workers"
        case pendingRendererRemovals = "pending_renderer_removals"
        case rendererReleaseRoutes = "renderer_release_routes"
        case browserRuntime = "browser_runtime"
        case frontendNativeBrowserRuntimes = "frontend_native_browser_runtimes"
        case remoteExternalProducerRuntimes = "remote_external_producer_runtimes"
        case sidebarPluginRuntime = "sidebar_plugin_runtime"
        case agentRecords = "agent_records"
        case unresolvedDurableMutation = "unresolved_durable_mutation"
        case unresolvedLaunchAttempts = "unresolved_launch_attempts"
        case durableStorageDegraded = "durable_storage_degraded"
    }
}

/// One unpredictable, connection-bound permission to replace an exact daemon.
public struct BackendServiceHandoffPermit: Codable, Equatable, Sendable {
    public let capability: String
    public let ownerConnectionID: UUID
    public let authority: BackendAuthority
    public let session: String
    public let sourceBuildID: String
    public let targetBuildID: String
    public let topologyRevision: UInt64
    public let canonicalTopologyRevision: UInt64
    public let durableStorage: BackendServiceDurableStorageStatus

    public init(
        capability: String,
        ownerConnectionID: UUID,
        authority: BackendAuthority,
        session: String,
        sourceBuildID: String,
        targetBuildID: String,
        topologyRevision: UInt64,
        canonicalTopologyRevision: UInt64,
        durableStorage: BackendServiceDurableStorageStatus
    ) {
        self.capability = capability
        self.ownerConnectionID = ownerConnectionID
        self.authority = authority
        self.session = session
        self.sourceBuildID = sourceBuildID
        self.targetBuildID = targetBuildID
        self.topologyRevision = topologyRevision
        self.canonicalTopologyRevision = canonicalTopologyRevision
        self.durableStorage = durableStorage
    }

    private enum CodingKeys: String, CodingKey {
        case capability
        case ownerConnectionID = "owner_connection_id"
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case session
        case sourceBuildID = "source_build_id"
        case targetBuildID = "target_build_id"
        case topologyRevision = "topology_revision"
        case canonicalTopologyRevision = "canonical_topology_revision"
        case durableStorage = "durable_storage"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capability = try container.decode(String.self, forKey: .capability)
        ownerConnectionID = try container.decode(UUID.self, forKey: .ownerConnectionID)
        authority = BackendAuthority(
            daemonInstanceID: try container.decode(
                DaemonInstanceID.self,
                forKey: .daemonInstanceID
            ),
            sessionID: try container.decode(SessionID.self, forKey: .sessionID)
        )
        session = try container.decode(String.self, forKey: .session)
        sourceBuildID = try container.decode(String.self, forKey: .sourceBuildID)
        targetBuildID = try container.decode(String.self, forKey: .targetBuildID)
        topologyRevision = try container.decode(UInt64.self, forKey: .topologyRevision)
        canonicalTopologyRevision = try container.decode(
            UInt64.self,
            forKey: .canonicalTopologyRevision
        )
        durableStorage = try container.decode(
            BackendServiceDurableStorageStatus.self,
            forKey: .durableStorage
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capability, forKey: .capability)
        try container.encode(ownerConnectionID, forKey: .ownerConnectionID)
        try container.encode(authority.daemonInstanceID, forKey: .daemonInstanceID)
        try container.encode(authority.sessionID, forKey: .sessionID)
        try container.encode(session, forKey: .session)
        try container.encode(sourceBuildID, forKey: .sourceBuildID)
        try container.encode(targetBuildID, forKey: .targetBuildID)
        try container.encode(topologyRevision, forKey: .topologyRevision)
        try container.encode(canonicalTopologyRevision, forKey: .canonicalTopologyRevision)
        try container.encode(durableStorage, forKey: .durableStorage)
    }
}

/// Result of asking the old daemon to enter authenticated idle draining.
public enum BackendServiceHandoffPreparation: Equatable, Sendable {
    case deferredNotIdle(BackendServiceHandoffBlockers)
    case prepared(BackendServiceHandoffPermit)
}

extension BackendServiceHandoffPreparation: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status
        case blockers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "deferred-not-idle":
            self = .deferredNotIdle(
                try container.decode(BackendServiceHandoffBlockers.self, forKey: .blockers)
            )
        case "prepared":
            self = .prepared(try BackendServiceHandoffPermit(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "unknown service handoff status \(status)"
            )
        }
    }
}

private struct BackendServiceHandoffCancellation: Decodable, Sendable {
    let status: String
}

public extension BackendProtocolClient {
    /// Atomically requests a one-shot permit for an exact staged build.
    func prepareServiceHandoff(
        targetBuildID: String
    ) async throws -> BackendServiceHandoffPreparation {
        try await call(
            command: "prepare-service-handoff",
            parameters: ["target_build_id": .string(targetBuildID)],
            as: BackendServiceHandoffPreparation.self
        )
    }

    /// Cancels one exact permit while its owner connection remains live.
    func cancelServiceHandoff(_ permit: BackendServiceHandoffPermit) async throws {
        let response: BackendServiceHandoffCancellation = try await call(
            command: "cancel-service-handoff",
            parameters: [
                "capability": .string(permit.capability),
                "source_build_id": .string(permit.sourceBuildID),
                "target_build_id": .string(permit.targetBuildID),
            ],
            as: BackendServiceHandoffCancellation.self
        )
        guard response.status == "cancelled" else {
            throw BackendProtocolError.malformedMessage
        }
    }
}
