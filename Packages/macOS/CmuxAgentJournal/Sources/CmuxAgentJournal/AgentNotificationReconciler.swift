internal import Foundation
internal import CryptoKit

/// Reconciles all providers' notification candidates on the journal's ordered consumer.
///
/// The session identity survives surface moves. Pending completions never reserve
/// an attention identity. Blocking requests are independent of completion identity,
/// so duplicate stops cannot swallow a later real approval. Replay observes state
/// through this same fold, but the caller never dispatches replay effects.
public struct AgentNotificationReconciler: Sendable {
    private struct Session: Sendable {
        var occurredAtMs: Int64 = -1
        var sequence: Int64 = 0
        var turn: String = "initial"
        var nativeTurn: String?
        var phase: AgentLifecyclePhase = .unknown
        var ended = false
        var attentionEpoch: Int64 = 0
        var children: Set<String> = []
        var delivered: [String: String] = [:]
        var starts: Set<String> = []
        var resolvedRequests: Set<String> = []
        var completionTurns: [String: String] = [:]
    }
    private var sessions: [String: Session] = [:]

    /// Creates an empty reconciler, suitable for live ingestion or journal replay.
    public init() {}

    /// Observes one committed semantic event and classifies its candidate.
    /// - Parameter event: A journal event with causal evidence from its adapter.
    /// - Returns: An admission candidate or a diagnostic explaining suppression.
    public mutating func apply(_ event: AgentJournalEvent) -> AgentNotificationDecision {
        let draft = event.draft
        guard draft.unattributedReason == nil, draft.surfaceId != nil,
              let sessionID = draft.sessionId, !sessionID.isEmpty else {
            return .init(.unattributed)
        }
        guard !draft.isSubagent else { return .init(.subagent) }
        let sessionKey = Self.key([draft.source, sessionID])
        var session = sessions[sessionKey] ?? Session()
        let context = draft.attention
        let incomingTurn = context?.turnIdentity
        if [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind),
           let request = context?.requestIdentity, session.resolvedRequests.contains(request) {
            return .init(.stale)
        }
        var requestInvalidations: [String] = []
        if draft.kind == .stateChanged, draft.declaredPhase == .running,
           let request = context?.requestIdentity {
            session.resolvedRequests.insert(request)
            let identity = Self.key([sessionKey, Self.key(["attention", request])])
            if let key = session.delivered.removeValue(forKey: identity) { requestInvalidations = [key] }
            sessions[sessionKey] = session
        }
        if draft.occurredAtMs < session.occurredAtMs
            || (draft.occurredAtMs == session.occurredAtMs && event.sequence < session.sequence) {
            return .init(.stale, invalidatedCorrelationKeys: requestInvalidations)
        }
        if draft.kind == .turnCompleted, let incomingTurn,
           let nativeTurn = session.nativeTurn, incomingTurn != nativeTurn {
            return .init(.stale)
        }
        if draft.kind == .turnStarted, let incomingTurn, incomingTurn == session.turn,
           session.phase == .needsInput || session.phase == .idle { return .init(.stale) }
        if draft.kind == .turnStarted, let key = context?.eventIdentity,
           session.starts.contains(key) { return .init(.stale) }
        if draft.kind == .turnCompleted, session.nativeTurn == nil, let incomingTurn {
            session.turn = incomingTurn
            session.nativeTurn = incomingTurn
        }
        if draft.kind == .turnCompleted, let key = context?.eventIdentity {
            if let boundTurn = session.completionTurns[key], boundTurn != session.turn { return .init(.stale) }
            session.completionTurns[key] = session.turn
        }
        var invalidated = requestInvalidations
        if draft.kind == .turnStarted || draft.kind == .sessionEnded
            || (draft.kind == .stateChanged && draft.declaredPhase == .running) {
            if draft.kind == .stateChanged, let request = context?.requestIdentity {
                let identity = Self.key([sessionKey, Self.key(["attention", request])])
                if let key = session.delivered.removeValue(forKey: identity) { invalidated = [key] }
            } else {
                invalidated = Array(session.delivered.values).sorted()
                session.delivered.removeAll()
            }
        }
        let previousPhase = session.phase
        switch draft.kind {
        case .sessionStarted:
            session.ended = false
        case .turnStarted:
            if let key = context?.eventIdentity { session.starts.insert(key) }
            session.turn = incomingTurn ?? context?.eventIdentity ?? draft.eventId
            session.nativeTurn = incomingTurn
            session.phase = .running
            session.ended = false
        case .turnCompleted:
            if session.turn == "initial", let incomingTurn { session.turn = incomingTurn }
            session.phase = draft.pendingWork || !session.children.isEmpty ? .running : .idle
        case .approvalRequested, .questionRequested, .planReviewRequested:
            if let incomingTurn { session.turn = incomingTurn; session.nativeTurn = incomingTurn }
            if previousPhase != .needsInput { session.attentionEpoch = event.sequence }
            session.phase = .needsInput
        case .errorReported:
            session.phase = .error
        case .sessionEnded:
            session.ended = true
        case .stateChanged:
            if let phase = draft.declaredPhase {
                session.phase = phase == .running && !session.delivered.isEmpty ? .needsInput : phase
            }
        case .childSpawned:
            if let child = context?.requestIdentity {
                session.children.insert(child)
                if session.phase == .idle || session.phase == .unknown { session.phase = .running }
            }
        case .childCompleted, .childFailed:
            if let child = context?.requestIdentity { session.children.remove(child) }
        }
        session.occurredAtMs = draft.occurredAtMs
        session.sequence = max(session.sequence, event.sequence)
        sessions[sessionKey] = session
        guard context?.notification != nil else { return .init(.observation, invalidatedCorrelationKeys: invalidated) }
        guard !session.ended else { return .init(.stale) }
        let boundary: String
        switch draft.kind {
        case .turnCompleted:
            guard session.phase == .idle else { return .init(.delayed) }
            boundary = Self.key(["completion", incomingTurn ?? session.turn])
        case .approvalRequested, .questionRequested, .planReviewRequested:
            // A real blocking request is never gated by background work.
            boundary = Self.key(["attention", context?.requestIdentity
                ?? "\(session.turn):\(session.attentionEpoch)"])
        case .errorReported:
            boundary = Self.key(["error", context?.eventIdentity ?? session.turn])
        default:
            return .init(.observation)
        }
        let identity = Self.key([sessionKey, boundary])
        session.delivered[identity] = context?.notification?.correlationKey ?? identity
        sessions[sessionKey] = session
        return .init(.accepted, identity: identity, invalidatedCorrelationKeys: invalidated)
    }

    /// Projects the reconciled phase back into the shared lifecycle fold.
    /// - Parameter event: The event just observed through `apply`.
    /// - Returns: A lifecycle assertion using the same causal state as admission.
    public func lifecycleEvent(_ event: AgentJournalEvent) -> AgentJournalEvent {
        var draft = event.draft
        guard let sessionID = draft.sessionId,
              let session = sessions[Self.key([draft.source, sessionID])] else { return event }
        switch draft.kind {
        case .turnCompleted:
            draft.pendingWork = session.phase == .running
        case .stateChanged where draft.declaredPhase != nil:
            draft.declaredPhase = session.phase
        case .childSpawned, .childCompleted, .childFailed:
            draft.kind = .stateChanged
            draft.declaredPhase = session.phase
        default:
            break
        }
        return AgentJournalEvent(sequence: event.sequence, committedAtMs: event.committedAtMs, draft: draft)
    }

    private static func key(_ components: [String]) -> String {
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
