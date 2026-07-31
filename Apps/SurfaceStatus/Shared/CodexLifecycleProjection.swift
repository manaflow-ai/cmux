import Foundation

struct SurfaceAgentLifecycle: Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case unknown
        case running
        case idle
        case done
        case needsInput
        case rateLimited
    }

    enum Reason: String, Codable, Sendable {
        case interaction
        case rateLimit
        case error
    }

    let agentID: String
    let state: State
    let reason: Reason?
    let updatedAt: TimeInterval
    let statusMessage: String?
}

struct CodexLaunchPresence: Equatable, Sendable {
    let surfaceID: String
    let pid: Int32
    let createdAt: TimeInterval
}

struct CodexLifecycleSession: Equatable, Sendable {
    let sessionID: String
    let agentLifecycle: SurfaceAgentLifecycle.State?
    let runtimeStatus: String?
    let pid: Int32?
    let surfaceID: String
    let updatedAt: TimeInterval?
}

struct CodexProcessSnapshot: Equatable, Sendable {
    let startedAt: TimeInterval
    let identity: NativeProcessIdentity?

    init(startedAt: TimeInterval, identity: NativeProcessIdentity? = nil) {
        self.startedAt = startedAt
        self.identity = identity
    }
}

enum CodexLifecycleProjection {
    typealias ProcessLookup = @Sendable (Int32) -> CodexProcessSnapshot?

    /// Projects cmux's persistent Codex hook records into sidebar-only state.
    /// The native store remains read-only. A record is eligible only when its
    /// attributed surface is valid and the exact process incarnation is still
    /// alive. This prevents a missing Stop/SessionEnd or PID reuse from leaving
    /// the sidebar stuck on Working.
    static func statuses(
        sessions: [String: CodexLifecycleSession],
        activeSessionsBySurface: [String: String]?,
        launches: [CodexLaunchPresence] = [],
        now: TimeInterval,
        processLookup: ProcessLookup
    ) -> [UUID: SurfaceAgentLifecycle] {
        var eligibleBySurface: [UUID: [CodexLifecycleSession]] = [:]

        for (sessionID, session) in sessions {
            guard session.sessionID == sessionID,
                  !sessionID.isEmpty,
                  let surfaceID = UUID(uuidString: session.surfaceID),
                  let pid = session.pid,
                  pid > 0,
                  let updatedAt = session.updatedAt,
                  updatedAt.isFinite,
                  updatedAt > 0,
                  updatedAt <= now + 300,
                  let process = processLookup(pid),
                  process.startedAt <= updatedAt else {
                continue
            }
            eligibleBySurface[surfaceID, default: []].append(session)
        }

        var result: [UUID: SurfaceAgentLifecycle] = [:]
        for (surfaceID, candidates) in eligibleBySurface {
            let activeSessionID = activeSessionsBySurface?[surfaceID.uuidString]
                ?? activeSessionsBySurface?[surfaceID.uuidString.lowercased()]
            let selected: CodexLifecycleSession
            if let activeSessionID {
                // A present per-surface owner is authoritative. If that exact
                // owner is dead or otherwise invalid, fail closed rather than
                // reviving an older live session for the same surface.
                guard let active = candidates.first(where: { $0.sessionID == activeSessionID }) else {
                    continue
                }
                selected = active
            } else {
                // Empty/absent maps are valid in stores observed in the field.
                // The native per-record surface attribution plus live process
                // incarnation remains authoritative; newest wins replacement.
                guard let newest = candidates.max(by: { lhs, rhs in
                    let lhsUpdated = lhs.updatedAt ?? 0
                    let rhsUpdated = rhs.updatedAt ?? 0
                    if lhsUpdated != rhsUpdated { return lhsUpdated < rhsUpdated }
                    return lhs.sessionID < rhs.sessionID
                }) else { continue }
                selected = newest
            }

            result[surfaceID] = lifecycle(for: selected)
        }
        for launch in launches {
            guard let surfaceID = UUID(uuidString: launch.surfaceID),
                  launch.pid > 0,
                  launch.createdAt.isFinite,
                  launch.createdAt > 0,
                  launch.createdAt <= now + 5,
                  let process = processLookup(launch.pid),
                  process.startedAt <= launch.createdAt,
                  launch.createdAt - process.startedAt <= 5,
                  result[surfaceID] == nil else {
                continue
            }
            result[surfaceID] = SurfaceAgentLifecycle(
                agentID: "codex",
                state: .idle,
                reason: nil,
                updatedAt: launch.createdAt,
                statusMessage: nil
            )
        }
        return result
    }

    private static func lifecycle(for session: CodexLifecycleSession) -> SurfaceAgentLifecycle {
        let runtime = session.runtimeStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        let state: SurfaceAgentLifecycle.State
        let reason: SurfaceAgentLifecycle.Reason?
        switch runtime {
        case "running":
            state = .running
            reason = nil
        case "idle":
            state = .idle
            reason = nil
        case "needsInput":
            state = .needsInput
            reason = .interaction
        case "error":
            state = .needsInput
            reason = .error
        default:
            state = session.agentLifecycle ?? .unknown
            reason = state == .needsInput ? .interaction : nil
        }
        return SurfaceAgentLifecycle(
            agentID: "codex",
            state: state,
            reason: reason,
            updatedAt: session.updatedAt ?? 0,
            statusMessage: nil
        )
    }
}
