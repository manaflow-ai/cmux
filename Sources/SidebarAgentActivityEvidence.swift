import CmuxWorkspaces
import Foundation

/// A deterministic observation used to project one agent's sidebar state.
///
/// The observation deliberately contains no terminal title, transcript-file
/// mtime, or process-name heuristic. A generation is either the exact hook
/// session token, the exact process generation cmux recorded, or a live
/// lifecycle event that has not yet been correlated to either.
struct SidebarAgentActivityEvidence: Equatable, Sendable {
    typealias Generation = SidebarAgentActivityGeneration

    let panelID: UUID
    let statusKey: String
    let generation: Generation
    let lifecycle: AgentHibernationLifecycleState?
    let startedAt: TimeInterval?
    let updatedAt: TimeInterval?
    let processLiveness: RestorableAgentProcessLiveness
    let hasExactProcessIdentity: Bool
    let isRuntimeBound: Bool
    let hasLiveLifecycleSignal: Bool
    let isHookBacked: Bool
    let isExactProcessBinding: Bool
    let isHeuristicProcessDetection: Bool

    var id: String {
        let canonicalStatusKey = SidebarWorkspaceAgentActivity.canonicalStatusKey(statusKey)
        let generationKey: String = switch generation {
        case .session(let sessionID):
            "session:" + ManagedAgentSessionIdentity.canonicalSessionID(
                kind: canonicalStatusKey,
                sessionID: sessionID
            )
        case .process(let identity):
            "process:\(identity.pid):\(identity.startSeconds):\(identity.startMicroseconds)"
        case .lifecycle:
            "lifecycle"
        }
        return panelID.uuidString + ":" + canonicalStatusKey + ":" + generationKey
    }

    /// Whether cmux can assert that this agent belongs on the row at all.
    /// Heuristic-only process detection is never presence evidence. A hook
    /// record still proves session presence when a heuristic scan makes its
    /// current liveness indeterminate.
    var hasDeterministicPresence: Bool {
        isRuntimeBound
            || hasLiveLifecycleSignal
            || isHookBacked
            || isExactProcessBinding
    }

    /// Combines observations for one exact session/process generation while
    /// giving a live cmux runtime signal authority over cached lifecycle state.
    func merged(with other: Self) -> Self {
        let hasLiveWorkspaceSignal = isRuntimeBound || hasLiveLifecycleSignal
        let otherHasLiveWorkspaceSignal = other.isRuntimeBound || other.hasLiveLifecycleSignal
        if hasLiveWorkspaceSignal || otherHasLiveWorkspaceSignal {
            let runtime: Self
            let cached: Self
            if otherHasLiveWorkspaceSignal && !hasLiveWorkspaceSignal {
                runtime = other
                cached = self
            } else if hasLiveWorkspaceSignal && !otherHasLiveWorkspaceSignal {
                runtime = self
                cached = other
            } else if other.hasExactProcessIdentity && !hasExactProcessIdentity {
                runtime = other
                cached = self
            } else {
                runtime = self
                cached = other
            }
            // Grouping by `id` already proved these observations describe the
            // same generation, so its durable SessionStart may safely outlive
            // a process respawn within that session.
            let elapsedAnchor = Self.preferredAnchor(
                hookCandidates: [
                    cached.isHookBacked ? cached.startedAt : nil,
                    runtime.isHookBacked ? runtime.startedAt : nil,
                ],
                fallbackCandidates: [runtime.startedAt, cached.startedAt]
            )
            return Self(
                panelID: panelID,
                statusKey: runtime.statusKey,
                generation: generation,
                lifecycle: runtime.lifecycle,
                startedAt: elapsedAnchor,
                updatedAt: max(updatedAt ?? 0, other.updatedAt ?? 0),
                processLiveness: runtime.processLiveness,
                hasExactProcessIdentity: runtime.hasExactProcessIdentity,
                isRuntimeBound: isRuntimeBound || other.isRuntimeBound,
                hasLiveLifecycleSignal: hasLiveLifecycleSignal || other.hasLiveLifecycleSignal,
                isHookBacked: isHookBacked || other.isHookBacked,
                isExactProcessBinding: runtime.isExactProcessBinding || cached.isExactProcessBinding,
                isHeuristicProcessDetection: false
            )
        }

        let newer = (other.updatedAt ?? 0) >= (updatedAt ?? 0) ? other : self
        return Self(
            panelID: panelID,
            statusKey: newer.statusKey,
            generation: generation,
            lifecycle: newer.lifecycle ?? lifecycle,
            startedAt: Self.preferredAnchor(
                hookCandidates: [
                    isHookBacked ? startedAt : nil,
                    other.isHookBacked ? other.startedAt : nil,
                ],
                fallbackCandidates: [startedAt, other.startedAt]
            ),
            updatedAt: max(updatedAt ?? 0, other.updatedAt ?? 0),
            processLiveness: newer.processLiveness,
            hasExactProcessIdentity: hasExactProcessIdentity || other.hasExactProcessIdentity,
            isRuntimeBound: false,
            hasLiveLifecycleSignal: false,
            isHookBacked: isHookBacked || other.isHookBacked,
            isExactProcessBinding: isExactProcessBinding || other.isExactProcessBinding,
            isHeuristicProcessDetection: isHeuristicProcessDetection
                || other.isHeuristicProcessDetection
        )
    }

    private static func firstValidAnchor(_ candidates: [TimeInterval?]) -> TimeInterval? {
        for candidate in candidates {
            if let candidate = validAnchor(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func preferredAnchor(
        hookCandidates: [TimeInterval?],
        fallbackCandidates: [TimeInterval?]
    ) -> TimeInterval? {
        let hookAnchors = hookCandidates.compactMap(validAnchor)
        if let hookAnchor = hookAnchors.min() {
            return hookAnchor
        }
        return firstValidAnchor(fallbackCandidates)
    }

    private static func validAnchor(_ candidate: TimeInterval?) -> TimeInterval? {
        guard let candidate,
              candidate.isFinite,
              candidate > 0 else {
            return nil
        }
        return candidate
    }
}
