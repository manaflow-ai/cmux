import Foundation

/// Persisted permission phase for one Codex session/runtime generation.
struct CodexPermissionState: Codable, Equatable, Sendable {
    var phase: CodexPermissionPhase
    var identity: CodexPermissionSignalIdentity
    var runtime: CodexPermissionRuntimeGeneration
    var revision: UInt64
    var notificationID: UUID?
    var resolvedIdentities: [CodexPermissionSignalIdentity]
    var startedIdentities: [CodexPermissionSignalIdentity]?
    var trackedRequests: [CodexPermissionRequest]?

    init(
        phase: CodexPermissionPhase,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration,
        revision: UInt64 = 1,
        notificationID: UUID? = nil,
        resolvedIdentities: [CodexPermissionSignalIdentity] = [],
        startedIdentities: [CodexPermissionSignalIdentity] = [],
        trackedRequests: [CodexPermissionRequest] = []
    ) {
        self.phase = phase
        self.identity = identity
        self.runtime = runtime
        self.revision = revision
        self.notificationID = notificationID
        self.resolvedIdentities = resolvedIdentities
        self.startedIdentities = startedIdentities.isEmpty ? nil : startedIdentities
        self.trackedRequests = trackedRequests.isEmpty ? nil : trackedRequests
    }

    /// Requests normalized from current storage and the legacy single-request fields.
    var normalizedTrackedRequests: [CodexPermissionRequest] {
        if let trackedRequests { return trackedRequests }
        guard phase == .needsInput else { return [] }
        return [
            CodexPermissionRequest(
                identity: identity,
                notificationID: notificationID,
                blocksInput: true
            ),
        ]
    }
}
