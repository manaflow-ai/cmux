import Darwin
import Foundation

struct AgentTurnProcessGeneration: Equatable, Sendable {
    let startSeconds: Int64
    let startMicroseconds: Int64
}

enum AgentTurnProcessGenerationReader {
    static func read(pid: Int?) -> AgentTurnProcessGeneration? {
        guard let pid,
              pid > 0,
              pid <= Int(Int32.max) else {
            return nil
        }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(
            pid_t(pid),
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        guard size == expectedSize else { return nil }
        return AgentTurnProcessGeneration(
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int64(info.pbi_start_tvusec)
        )
    }
}

enum AgentTurnBoundary: String, Codable, Sendable {
    /// A low-level agent-end/Stop signal. It is provisional while structured
    /// background work remains.
    case turnEnd = "turn_end"
    /// The integration has confirmed its own idle/settled condition.
    case settled
}

enum AgentTurnProcessLiveness: String, Codable, Sendable {
    case live
    case unknown
    case exited

    static func observe(
        pid: Int?,
        expectedStartSeconds: Int64? = nil,
        expectedStartMicroseconds: Int64? = nil
    ) -> Self {
        guard let pid, pid > 0, pid <= Int(Int32.max) else {
            return .unknown
        }
        if let expectedStartSeconds, let expectedStartMicroseconds {
            if let processGeneration =
                AgentTurnProcessGenerationReader.read(pid: pid) {
                let generationMatches =
                    processGeneration.startSeconds == expectedStartSeconds
                    && processGeneration.startMicroseconds
                        == expectedStartMicroseconds
                return generationMatches ? .live : .exited
            }
        }
        if Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM {
            // A numeric PID without a readable start identity is live, but
            // cannot prove it is the generation that emitted this hook.
            return expectedStartSeconds == nil
                || expectedStartMicroseconds == nil
                ? .live
                : .unknown
        }
        return errno == ESRCH ? .exited : .unknown
    }
}

enum AgentTurnFreshness: String, Codable, Sendable {
    case current
    case superseded
    case unknown
}

struct AgentTurnSettlementEvidence: Equatable, Sendable {
    let boundary: AgentTurnBoundary
    let activeBackgroundWorkCount: Int
    let processLiveness: AgentTurnProcessLiveness
    let turnFreshness: AgentTurnFreshness

    init(
        boundary: AgentTurnBoundary,
        activeBackgroundWorkCount: Int,
        processLiveness: AgentTurnProcessLiveness,
        turnFreshness: AgentTurnFreshness = .unknown
    ) {
        self.boundary = boundary
        self.activeBackgroundWorkCount = max(0, activeBackgroundWorkCount)
        self.processLiveness = processLiveness
        self.turnFreshness = turnFreshness
    }
}

enum AgentTurnSettlementDecision: Equatable, Sendable {
    case keepRunning
    case settle
    case terminateWithoutCompletion
}

enum AgentTurnSettlementPolicy: Sendable {
    /// A Stop is authoritative only when no structured work remains.
    case turnEndWhenNoBackgroundWork
    /// A low-level end signal is always provisional. The integration must
    /// publish an explicit settled boundary after its work set becomes empty.
    case requiresSettledBoundary
}

struct AgentTurnSettlementReconciler {
    static func resolve(
        integration: BuiltInAgentIntegration,
        evidence: AgentTurnSettlementEvidence
    ) -> AgentTurnSettlementDecision {
        // A hook from an older turn cannot clear or terminate the newer turn,
        // even if that older hook reports a dead process generation.
        if evidence.turnFreshness == .superseded {
            return .keepRunning
        }
        if evidence.processLiveness == .exited {
            return .terminateWithoutCompletion
        }
        if evidence.activeBackgroundWorkCount > 0 {
            return .keepRunning
        }
        if integration.turnSettlementPolicy == .requiresSettledBoundary,
           evidence.boundary != .settled {
            return .keepRunning
        }
        return .settle
    }

    static func classifyTurnFreshness(
        incomingTurnId: String?,
        activeTurnIds: [String],
        activeTurnDepth: Int? = nil,
        latestTurnId: String?,
        terminalTurnIds: [String]
    ) -> AgentTurnFreshness {
        guard let incomingTurnId = normalizedTurnId(incomingTurnId) else {
            return .unknown
        }
        let activeTurnIds = Set(activeTurnIds.compactMap(normalizedTurnId))
        let terminalTurnIds = Set(
            terminalTurnIds.compactMap(normalizedTurnId)
        )
        if terminalTurnIds.contains(incomingTurnId) {
            return .superseded
        }
        if !activeTurnIds.isEmpty {
            return activeTurnIds.contains(incomingTurnId)
                ? .current
                : .superseded
        }
        if max(0, activeTurnDepth ?? 0) > activeTurnIds.count {
            // Legacy hooks can report nesting depth without identifying the
            // still-active parent turn. A completed child remains `latest`,
            // but cannot prove that a later named Stop is stale.
            return .unknown
        }
        if let latestTurnId = normalizedTurnId(latestTurnId) {
            return latestTurnId == incomingTurnId
                ? .current
                : .superseded
        }
        return .unknown
    }

    private static func normalizedTurnId(_ value: String?) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }
}
