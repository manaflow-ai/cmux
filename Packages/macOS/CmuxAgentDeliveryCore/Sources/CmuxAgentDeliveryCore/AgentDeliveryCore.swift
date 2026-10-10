public import Foundation

/// The live surface a hook completion should address.
public struct AgentDeliveryTargetCandidate: Equatable, Sendable {
    /// The workspace currently presenting the surface.
    public let workspaceId: UUID
    /// The terminal or browser surface currently owned by that workspace.
    public let surfaceId: UUID

    /// Creates a delivery target from live workspace and surface identity.
    public init(workspaceId: UUID, surfaceId: UUID) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
    }
}

/// The process scope recovered from the exact process being resolved.
public struct CmuxTopProcessScope: Sendable, Equatable {
    /// The workspace claimed by the process environment or hook arguments.
    public let workspaceID: UUID?
    /// The surface claimed by the process environment or hook arguments.
    public let surfaceID: UUID?
    /// The evidence source used to recover the scope.
    public let attributionReason: String

    /// Creates a process scope value without performing any process inspection.
    public init(workspaceID: UUID?, surfaceID: UUID?, attributionReason: String) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.attributionReason = attributionReason
    }
}

/// A PID plus birth time, used to reject evidence after PID reuse.
public struct CmuxTopProcessScopeCacheKey: Hashable, Sendable {
    /// The process identifier.
    public let pid: Int
    /// The process birth time in seconds.
    public let startSeconds: Int
    /// The process birth time's microsecond component.
    public let startMicroseconds: Int

    /// Creates a start-time-keyed process identity.
    public init(pid: Int, startSeconds: Int, startMicroseconds: Int) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

/// Immutable process facts collected before a MainActor ownership lookup.
public struct AgentDeliveryProcessEvidence: Sendable, Equatable {
    /// Whether the process was alive when it was inspected.
    public let isLive: Bool
    /// The process's controlling-terminal device, when one was available.
    public let ttyDevice: Int64?
    /// Scope claims recovered from the process's environment or arguments.
    public let scope: CmuxTopProcessScope?
    /// The process birth-time key used to bind this evidence.
    public let scopeCacheKey: CmuxTopProcessScopeCacheKey?

    /// Creates immutable evidence for a later actor-boundary handoff.
    public init(
        isLive: Bool,
        ttyDevice: Int64?,
        scope: CmuxTopProcessScope?,
        scopeCacheKey: CmuxTopProcessScopeCacheKey?
    ) {
        self.isLive = isLive
        self.ttyDevice = ttyDevice
        self.scope = scope
        self.scopeCacheKey = scopeCacheKey
    }
}

/// Selects how a PID claim is trusted during delivery resolution.
public enum AgentProcessBindingResolution: String, Sendable {
    /// Require controlling-TTY and process-scope evidence to agree.
    case corroborated
    /// Trust only the process's controlling terminal.
    case controllingTTY = "controlling_tty"
}

/// Selects the authenticated source for a remote TTY claim.
public enum AgentTTYBindingResolution: String, Sendable {
    /// The report came from the current terminal runtime.
    case reportedTTY = "reported_tty"
}

/// Abstracts process inspection from the pure delivery rules and AppKit state.
public protocol AgentDeliveryProcessInspector: Sendable {
    /// Inspects one PID without reading workspace, window, or Dock state.
    nonisolated func inspect(
        pid: Int32,
        resolution: AgentProcessBindingResolution
    ) -> AgentDeliveryProcessEvidence
}

/// Combines controlling-TTY and process-scope claims under the trust policy.
public func agentDeliveryTargetCombining(
    ttyTarget: AgentDeliveryTargetCandidate?,
    envTarget: AgentDeliveryTargetCandidate?,
    resolution: AgentProcessBindingResolution = .corroborated
) -> AgentDeliveryTargetCandidate? {
    if resolution == .controllingTTY { return ttyTarget }
    guard let ttyTarget else { return envTarget }
    if let envTarget, envTarget.surfaceId != ttyTarget.surfaceId { return nil }
    return ttyTarget
}

/// Finds a unique surface whose PTY device matches a process's controlling TTY.
public func agentDeliveryTargetMatchingTTYDevice(
    _ ttyDevice: Int64,
    surfaceTTYDevices: [(workspaceId: UUID, surfaceId: UUID, ttyDevice: Int64)]
) -> AgentDeliveryTargetCandidate? {
    let matches = surfaceTTYDevices.filter { $0.ttyDevice == ttyDevice }
    guard let first = matches.first,
          matches.allSatisfy({ $0.workspaceId == first.workspaceId && $0.surfaceId == first.surfaceId }) else {
        return nil
    }
    return AgentDeliveryTargetCandidate(workspaceId: first.workspaceId, surfaceId: first.surfaceId)
}

/// Verifies that evidence still belongs to the process observed at delivery.
public func agentDeliveryEvidenceMatchesProcess(
    _ evidence: AgentDeliveryProcessEvidence,
    currentScopeCacheKey: CmuxTopProcessScopeCacheKey?
) -> Bool {
    evidence.isLive && evidence.scopeCacheKey != nil && evidence.scopeCacheKey == currentScopeCacheKey
}
