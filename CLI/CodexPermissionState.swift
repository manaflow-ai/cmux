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

    init(
        phase: CodexPermissionPhase,
        identity: CodexPermissionSignalIdentity,
        runtime: CodexPermissionRuntimeGeneration,
        revision: UInt64 = 1,
        notificationID: UUID? = nil,
        resolvedIdentities: [CodexPermissionSignalIdentity] = [],
        startedIdentities: [CodexPermissionSignalIdentity] = []
    ) {
        self.phase = phase
        self.identity = identity
        self.runtime = runtime
        self.revision = revision
        self.notificationID = notificationID
        self.resolvedIdentities = resolvedIdentities
        self.startedIdentities = startedIdentities.isEmpty ? nil : startedIdentities
    }
}
