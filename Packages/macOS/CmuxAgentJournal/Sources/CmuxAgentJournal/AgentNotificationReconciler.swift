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
        var seenTurns: Set<String> = []
        var phase: AgentLifecyclePhase = .unknown
        var ended = false
        var attentionEpoch: Int64 = 0
        var children: Set<String> = []
        var finishedChildren: Set<String> = []
        var rootStopped = false
        var pendingCompletion: AgentJournalEvent?
        var delivered: [String: String] = [:]
        // Blocking requests, separate from error and completion history.
        var attentionIdentities: Set<String> = []
        var attentionRequestIDs: [String: String] = [:]
        var completionIdentity: String?
        var starts: Set<String> = []
        var resolvedRequests: Set<String> = []
        var completionTurns: [String: String] = [:]

        /// The agent continues after the user's decision: a settled turn is live again.
        mutating func resumeWork() {
            rootStopped = false
            pendingCompletion = nil
            phase = .running
        }

        /// Retires one pending blocking request, returning its producer dismissal handle.
        mutating func retireAttention(_ identity: String) -> String? {
            attentionIdentities.remove(identity)
            if let request = attentionRequestIDs.removeValue(forKey: identity) { resolvedRequests.insert(request) }
            return delivered.removeValue(forKey: identity)
        }
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
        if draft.kind == .stateChanged, draft.declaredPhase == nil { return .init(.observation) }
        let incomingTurn = context?.turnIdentity
        if [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind),
           let request = context?.requestIdentity, session.resolvedRequests.contains(request) {
            return .init(.stale)
        }
        let isResolution = draft.kind == .attentionResolved
            || draft.kind == .childCompleted || draft.kind == .childFailed
        var requestInvalidations: [String] = []
        if isResolution {
            // A work observation is not a resolution. Only this explicit semantic
            // event can retire an immutable request/child ID behind a newer watermark.
            // A late reply still retires its own request, but it never reopens a
            // turn that settled after it.
            let fresh = draft.occurredAtMs >= session.occurredAtMs
            if let request = context?.requestIdentity {
                if draft.kind == .attentionResolved {
                    let wasResolved = session.resolvedRequests.contains(request)
                    session.resolvedRequests.insert(request)
                    let identity = Self.key([sessionKey, Self.key(["attention", request])])
                    if let key = session.retireAttention(identity) { requestInvalidations.append(key) }
                    if draft.pendingWork && !wasResolved && fresh { session.resumeWork() }
                } else {
                    session.finishedChildren.insert(request)
                    session.children.remove(request)
                }
            } else if draft.kind == .attentionResolved, fresh,
                      context?.turnIdentity == session.nativeTurn,
                      session.attentionIdentities.count == 1,
                      let identity = session.attentionIdentities.first {
                // An identity-less reply answers only the one request pending on
                // its own turn. An ambiguous or older reply keeps the wait.
                if let key = session.retireAttention(identity) { requestInvalidations.append(key) }
                if draft.pendingWork { session.resumeWork() }
            }
            if !session.attentionIdentities.isEmpty {
                session.phase = .needsInput
            } else if session.rootStopped && session.children.isEmpty {
                session.phase = .idle
            } else if session.phase == .needsInput {
                session.phase = .running
            }
            session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
            session.sequence = max(session.sequence, event.sequence)
            let pending = session.phase == .idle && !session.ended ? session.pendingCompletion : nil
            if pending != nil { session.pendingCompletion = nil }
            sessions[sessionKey] = session
            if let pending {
                var completion = pending.draft
                completion.occurredAtMs = session.occurredAtMs
                completion.pendingWork = false
                let released = AgentJournalEvent(sequence: session.sequence, committedAtMs: event.committedAtMs, draft: completion)
                let decision = apply(released)
                return .init(decision.disposition, identity: decision.identity,
                    invalidatedCorrelationKeys: requestInvalidations + decision.invalidatedCorrelationKeys,
                    notificationEvent: released)
            }
            return .init(.observation, invalidatedCorrelationKeys: requestInvalidations)
        }
        let isAttention = [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind)
        if isAttention, let incomingTurn, let currentTurn = session.nativeTurn,
           incomingTurn != currentTurn, session.seenTurns.contains(incomingTurn) { return .init(.stale) }
        if isAttention, context?.requestIdentity == nil, !session.attentionIdentities.isEmpty {
            // A generic permission reminder adds no new request identity. Do not
            // let it re-notify or advance the watermark past a real later request.
            guard context?.notification != nil else { return .init(.observation, projectsLifecycle: false) }
            guard session.attentionIdentities.count == 1,
                  let identity = session.attentionIdentities.first else { return .init(.observation, projectsLifecycle: false) }
            var reminder = draft
            reminder.attention?.notification?.correlationKey = session.delivered[identity]
            return .init(.accepted, identity: identity,
                notificationEvent: AgentJournalEvent(sequence: event.sequence, committedAtMs: event.committedAtMs, draft: reminder),
                projectsLifecycle: false)
        }
        let independentRequest = isAttention && context?.requestIdentity != nil && session.phase == .needsInput
        if !independentRequest && (draft.occurredAtMs < session.occurredAtMs
            || (draft.occurredAtMs == session.occurredAtMs && event.sequence < session.sequence)) {
            return .init(.stale)
        }
        if draft.kind == .messagePublished {
            guard !session.ended else { return .init(.stale) }
            guard context?.notification != nil else { return .init(.observation) }
            let key = context?.requestIdentity ?? context?.eventIdentity ?? draft.eventId
            return .init(.accepted, identity: Self.key([sessionKey, "message", key]))
        }
        if (draft.kind == .turnCompleted || draft.kind == .idleObserved), let incomingTurn,
           let nativeTurn = session.nativeTurn, incomingTurn != nativeTurn {
            guard session.phase != .running, session.phase != .needsInput,
                  !session.seenTurns.contains(incomingTurn) else { return .init(.stale) }
            session.turn = incomingTurn
            session.nativeTurn = incomingTurn
            session.completionIdentity = nil
        }
        if draft.kind == .idleObserved {
            let matchesTurn = context?.turnIdentity != nil && context?.turnIdentity == session.nativeTurn
            guard !draft.pendingWork, session.attentionIdentities.isEmpty, session.children.isEmpty,
                  session.phase == .idle || session.phase == .unknown || (session.phase == .running && matchesTurn),
                  !session.ended else { return .init(.delayed, projectsLifecycle: false) }
            session.phase = .idle
            session.rootStopped = true
            session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
            session.sequence = max(session.sequence, event.sequence)
            sessions[sessionKey] = session
            guard context?.notification != nil else { return .init(.observation) }
            let identity = Self.key([sessionKey, Self.key(["completion", context?.turnIdentity ?? session.turn])])
            session.delivered[identity] = context?.notification?.correlationKey ?? identity
            session.completionIdentity = identity
            sessions[sessionKey] = session
            return .init(.accepted, identity: identity)
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
        var invalidated: [String] = []
        if draft.kind == .turnStarted || draft.kind == .sessionEnded {
            invalidated = Array(session.delivered.values).sorted()
            session.delivered.removeAll()
            session.attentionIdentities.removeAll()
            session.resolvedRequests.formUnion(session.attentionRequestIDs.values)
            session.attentionRequestIDs.removeAll()
            session.completionIdentity = nil
            session.pendingCompletion = nil
        }
        let previousPhase = session.phase
        switch draft.kind {
        case .messagePublished, .attentionResolved, .idleObserved:
            return .init(.observation)
        case .sessionStarted:
            if session.ended { session.phase = .unknown; session.nativeTurn = nil }
            session.ended = false
        case .turnStarted:
            session.rootStopped = false
            if let key = context?.eventIdentity { session.starts.insert(key) }
            if incomingTurn != nil || context?.eventIdentity != nil || session.phase != .running {
                session.turn = incomingTurn ?? context?.eventIdentity ?? draft.eventId
                session.nativeTurn = incomingTurn
            }
            session.phase = .running
            session.ended = false
        case .turnCompleted:
            session.rootStopped = !draft.pendingWork
            if !draft.pendingWork, !session.children.isEmpty, context?.notification != nil {
                session.pendingCompletion = event
            }
            if session.turn == "initial", let incomingTurn { session.turn = incomingTurn }
            let pending = draft.pendingWork || !session.children.isEmpty
            if !draft.pendingWork {
                for identity in session.delivered.keys.sorted() where identity != session.completionIdentity {
                    if let key = session.delivered.removeValue(forKey: identity) { invalidated.append(key) }
                }
                session.attentionIdentities.removeAll()
                session.resolvedRequests.formUnion(session.attentionRequestIDs.values)
                session.attentionRequestIDs.removeAll()
            }
            session.phase = pending ? (session.attentionIdentities.isEmpty ? .running : .needsInput) : .idle
        case .approvalRequested, .questionRequested, .planReviewRequested:
            if let incomingTurn { session.turn = incomingTurn; session.nativeTurn = incomingTurn }
            if previousPhase != .needsInput { session.attentionEpoch = event.sequence }
            session.phase = .needsInput
        case .errorReported:
            session.phase = .error
        case .sessionEnded:
            session.ended = true
        case .stateChanged:
            if draft.declaredPhase == .running {
                session.rootStopped = false
                session.pendingCompletion = nil
            }
            if let phase = draft.declaredPhase {
                session.phase = phase == .running && !session.attentionIdentities.isEmpty ? .needsInput : phase
            }
        case .childSpawned:
            if let child = context?.requestIdentity, !session.finishedChildren.contains(child) {
                session.children.insert(child)
                if session.phase == .idle || session.phase == .unknown { session.phase = .running }
            }
        case .childCompleted, .childFailed:
            if let child = context?.requestIdentity { session.children.remove(child) }
        }
        if let turn = session.nativeTurn { session.seenTurns.insert(turn) }
        session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
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
        if [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind) {
            session.attentionIdentities.insert(identity)
            if let request = context?.requestIdentity { session.attentionRequestIDs[identity] = request }
        }
        if draft.kind == .turnCompleted { session.completionIdentity = identity }
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
        case .sessionStarted where session.phase != .unknown:
            draft.kind = .stateChanged
            draft.declaredPhase = session.phase
        case .turnCompleted:
            if session.phase == .needsInput {
                draft.kind = .stateChanged
                draft.declaredPhase = .needsInput
            } else {
                draft.pendingWork = session.phase == .running
            }
        case .stateChanged where draft.declaredPhase != nil:
            draft.declaredPhase = session.phase
        case .idleObserved, .attentionResolved, .childSpawned, .childCompleted, .childFailed:
            draft.occurredAtMs = max(draft.occurredAtMs, session.occurredAtMs)
            draft.kind = .stateChanged
            draft.declaredPhase = session.phase
        default:
            break
        }
        return AgentJournalEvent(sequence: event.sequence, committedAtMs: event.committedAtMs, draft: draft)
    }

    private static func key(_ components: [String]) -> String {
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined()
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(framed.utf8)) {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
