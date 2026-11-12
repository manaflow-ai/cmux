internal import Foundation
internal import CryptoKit

/// Reconciles all providers' notification candidates on the journal's ordered consumer.
///
/// The session identity survives surface moves. Pending completions never reserve
/// an attention identity. Blocking requests are independent of completion identity,
/// so duplicate stops cannot swallow a later real approval. Replay observes state
/// through this same fold, but the caller never dispatches replay effects.
public struct AgentNotificationReconciler: Sendable {
    /// The newest accepted owner for one surface and agent pair.
    private struct SessionBoundary: Sendable {
        let sessionKey: String
        let sequence: Int64
    }

    private struct Session: Sendable {
        var occurredAtMs: Int64 = -1
        var sequence: Int64 = 0
        var surfaceID: String?
        var agentKey: String?
        /// Surfaces this session has intentionally left. A late event from one
        /// of these panes cannot move the session back without a fresh
        /// SessionStart ownership boundary.
        var retiredSurfaceIDs: Set<String> = []
        var superseded = false
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
        var deliveredSurfaceIDs: [String: String] = [:]
        // Blocking requests, separate from error and completion history.
        var attentionIdentities: Set<String> = []
        var attentionRequestIDs: [String: String] = [:]
        var completionIdentity: String?
        /// The settled turn reopened (a continuation without a new prompt)
        /// after its completion notified. Its next Stop reuses that completion
        /// identity and is deduplicated, so its idle reminder is the only signal
        /// left and must not be treated as repeating the already-read completion.
        var reopenedSinceCompletion = false
        var starts: Set<String> = []
        var resolvedRequests: Set<String> = []
        var completionTurns: [String: String] = [:]

        /// The agent continues after the user's decision: a settled turn is live again.
        mutating func resumeWork() {
            rootStopped = false
            pendingCompletion = nil
            phase = .running
            if completionIdentity != nil { reopenedSinceCompletion = true }
        }

        /// Retires one pending blocking request, returning its producer dismissal handle.
        mutating func retireAttention(_ identity: String) -> String? {
            attentionIdentities.remove(identity)
            if let request = attentionRequestIDs.removeValue(forKey: identity) { resolvedRequests.insert(request) }
            return delivered.removeValue(forKey: identity)
        }
    }
    private var sessions: [String: Session] = [:]
    /// Historical sessions are indexed only while they can receive events.
    /// Superseded, ended, and moved sessions are removed to keep boundaries
    /// cheap even when the journal contains a long history.
    private var sessionKeysBySurfaceAndAgent: [String: Set<String>] = [:]
    private var sessionBoundaries: [String: SessionBoundary] = [:]

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
        let boundaryKey = Self.surfaceAgentKey(surfaceID: draft.surfaceId!, agentKey: draft.agentKey)
        if let boundary = sessionBoundaries[boundaryKey], boundary.sessionKey != sessionKey {
            // The lifecycle reducer's per-surface boundary is the authority:
            // an older session cannot invalidate a newer owner's receipts.
            if draft.kind != .sessionStarted || event.sequence <= boundary.sequence {
                return .init(.stale)
            }
        }
        if draft.kind == .sessionStarted,
           let existing = sessions[sessionKey],
           event.sequence <= existing.sequence
                || draft.occurredAtMs < existing.occurredAtMs {
            return .init(.stale)
        }
        if draft.kind == .sessionStarted,
           sessions[sessionKey]?.superseded == true {
            // Session boundaries are one-way. A late start from a retired
            // identity must not make it current again or invalidate the
            // receipts of the replacement owner.
            return .init(.stale)
        }
        var boundaryInvalidations: [String] = []
        if draft.kind == .sessionStarted, draft.sessionStartOwnsSurface {
            // A new session boundary supersedes every older session that was
            // attached to this pane. Release their delivered notifications
            // through the same correlation-key path as attention resolution.
            let indexedKeys = sessionKeysBySurfaceAndAgent[boundaryKey, default: []]
            for key in indexedKeys where key != sessionKey {
                guard var candidate = sessions[key] else { continue }
                boundaryInvalidations.append(contentsOf: candidate.delivered.values)
                candidate.delivered.removeAll()
                candidate.deliveredSurfaceIDs.removeAll()
                candidate.attentionIdentities.removeAll()
                candidate.attentionRequestIDs.removeAll()
                candidate.pendingCompletion = nil
                candidate.ended = true
                candidate.superseded = true
                sessions[key] = candidate
                sessionKeysBySurfaceAndAgent[boundaryKey]?.remove(key)
            }
        }
        var session = sessions[sessionKey] ?? Session()
        let originalSessionBeforeMove = session
        if session.superseded && draft.kind != .sessionStarted {
            return .init(.stale, invalidatedCorrelationKeys: boundaryInvalidations)
        }
        if draft.kind != .sessionStarted,
           let currentSurfaceID = session.surfaceID,
           currentSurfaceID != draft.surfaceId,
           session.retiredSurfaceIDs.contains(draft.surfaceId!) {
            // A session move is one-way until the provider emits a fresh
            // SessionStart. Do not let a delayed hook from the old pane revive
            // its retired error, status, or notification state.
            return .init(.stale, invalidatedCorrelationKeys: boundaryInvalidations)
        }
        if let previousSurfaceID = session.surfaceID, previousSurfaceID != draft.surfaceId {
            // Correlations are pane-scoped even though the semantic session
            // identity survives a move. Retire receipts on the old pane while
            // their originating surface is still known.
            for identity in Array(session.delivered.keys)
                where session.deliveredSurfaceIDs[identity] == previousSurfaceID {
                if let correlation = session.delivered.removeValue(forKey: identity) {
                    boundaryInvalidations.append(correlation)
                }
                session.deliveredSurfaceIDs.removeValue(forKey: identity)
            }
        }
        if draft.kind == .sessionStarted, sessions[sessionKey] != nil {
            // A reused native session id still marks a new authoritative
            // boundary after restart, /clear, or auto-resume. Retire every
            // receipt from the prior turn and reset its lifecycle projection
            // before later hooks can reuse the old StopFailure state.
            boundaryInvalidations.append(contentsOf: session.delivered.values)
            let seenTurns = session.seenTurns
            let retiredSurfaceIDs = session.retiredSurfaceIDs
            let previousSurfaceID = session.surfaceID
            session = Session()
            session.surfaceID = draft.surfaceId
            session.agentKey = draft.agentKey
            session.retiredSurfaceIDs = retiredSurfaceIDs
            if let previousSurfaceID, previousSurfaceID != draft.surfaceId {
                session.retiredSurfaceIDs.insert(previousSurfaceID)
            }
            session.retiredSurfaceIDs.remove(draft.surfaceId!)
            // Keep the old turn watermark so a late completion from the
            // superseded turn remains stale after the recovery reset.
            session.seenTurns = seenTurns
        }
        let movedFromPreviousSurface = session.surfaceID != nil && session.surfaceID != draft.surfaceId
        if movedFromPreviousSurface,
           let previousSurfaceID = session.surfaceID {
            session.retiredSurfaceIDs.insert(previousSurfaceID)
            session.retiredSurfaceIDs.remove(draft.surfaceId!)
        }
        session.surfaceID = draft.surfaceId
        session.agentKey = draft.agentKey

        /// Commits a pane move even when the event is later suppressed by an
        /// identity or freshness guard, preserving origin invalidations and
        /// the move watermark together.
        func finalizeMovedDecision(_ decision: AgentNotificationDecision) -> AgentNotificationDecision {
            guard movedFromPreviousSurface else { return decision }
            let moveIsFresh = draft.occurredAtMs > originalSessionBeforeMove.occurredAtMs
                || (draft.occurredAtMs == originalSessionBeforeMove.occurredAtMs
                    && event.sequence > originalSessionBeforeMove.sequence)
            guard moveIsFresh else {
                session = originalSessionBeforeMove
                return decision
            }
            session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
            session.sequence = max(session.sequence, event.sequence)
            storeSession(session, for: sessionKey, indexKey: boundaryKey)
            guard !boundaryInvalidations.isEmpty else { return decision }
            return .init(
                decision.disposition,
                identity: decision.identity,
                invalidatedCorrelationKeys: boundaryInvalidations + decision.invalidatedCorrelationKeys,
                notificationEvent: decision.notificationEvent,
                projectsLifecycle: decision.projectsLifecycle,
                remindedCompletion: decision.remindedCompletion
            )
        }
        let context = draft.attention
        if draft.kind == .stateChanged, draft.declaredPhase == nil {
            if !movedFromPreviousSurface {
                storeSession(session, for: sessionKey, indexKey: boundaryKey)
                return .init(.observation)
            }
            return finalizeMovedDecision(.init(.observation))
        }
        let incomingTurn = context?.turnIdentity
        if [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind),
           let request = context?.requestIdentity, session.resolvedRequests.contains(request) {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        let isResolution = draft.kind == .attentionResolved
            || draft.kind == .childCompleted || draft.kind == .childFailed
        var requestInvalidations: [String] = boundaryInvalidations
        if isResolution {
            // A work observation is not a resolution. Only this explicit semantic
            // event can retire an immutable request/child ID behind a newer watermark.
            // A late reply still retires its own request. Only a fresh running
            // tool event may reopen a settled turn.
            let fresh = draft.occurredAtMs > session.occurredAtMs
                || (draft.occurredAtMs == session.occurredAtMs && event.sequence > session.sequence)
            let isIdentitylessToolStart = incomingTurn == nil
                && draft.nativeEvent?.caseInsensitiveCompare("PreToolUse") == .orderedSame
            let incomingTurn = context?.turnIdentity
            let isNewTurn = incomingTurn != nil
                && session.nativeTurn != nil
                && incomingTurn != session.nativeTurn
            if draft.kind == .attentionResolved, draft.declaredPhase == .running, fresh,
               !session.ended,
               draft.pendingWork
                || (isNewTurn && incomingTurn.map { !session.seenTurns.contains($0) } == true)
                || (isIdentitylessToolStart && fresh) {
                // A tool completion is progress, including a continuation
                // that starts without UserPromptSubmit. Reopen only fresh
                // activity with a new turn identity; an older or same-turn
                // result cannot resurrect a settled pane.
                if let incomingTurn, isNewTurn {
                    session.turn = incomingTurn
                    session.nativeTurn = incomingTurn
                }
                session.resumeWork()
            }
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
            } else if draft.declaredPhase == .idle {
                // Only an idle declaration (a dismissed idle dialog) settles the
                // turn. Fresh tool activity explicitly reopens it below.
                session.phase = .idle
                session.rootStopped = true
            } else if session.rootStopped && session.children.isEmpty {
                session.phase = .idle
            } else if session.phase == .needsInput {
                session.phase = .running
            }
            session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
            session.sequence = max(session.sequence, event.sequence)
            let pending = session.phase == .idle && !session.ended ? session.pendingCompletion : nil
            if pending != nil { session.pendingCompletion = nil }
            storeSession(session, for: sessionKey, indexKey: boundaryKey)
            if let pending {
                var completion = pending.draft
                completion.occurredAtMs = session.occurredAtMs
                completion.pendingWork = false
                let released = AgentJournalEvent(sequence: session.sequence, committedAtMs: event.committedAtMs, draft: completion)
                let decision = apply(released)
                return .init(decision.disposition, identity: decision.identity,
                    invalidatedCorrelationKeys: requestInvalidations + decision.invalidatedCorrelationKeys,
                    notificationEvent: released, remindedCompletion: decision.remindedCompletion)
            }
            return .init(.observation, invalidatedCorrelationKeys: requestInvalidations)
        }
        let isAttention = [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind)
        if isAttention, let incomingTurn, let currentTurn = session.nativeTurn,
           incomingTurn != currentTurn, session.seenTurns.contains(incomingTurn) {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        if isAttention, context?.requestIdentity == nil, !session.attentionIdentities.isEmpty {
            // A generic permission reminder adds no new request identity. Do not
            // let it re-notify or advance the watermark past a real later request.
            guard context?.notification != nil else {
                return finalizeMovedDecision(.init(.observation, projectsLifecycle: false))
            }
            guard session.attentionIdentities.count == 1,
                  let identity = session.attentionIdentities.first else {
                return finalizeMovedDecision(.init(.observation, projectsLifecycle: false))
            }
            var reminder = draft
            reminder.attention?.notification?.correlationKey = session.delivered[identity]
            return finalizeMovedDecision(.init(.accepted, identity: identity,
                notificationEvent: AgentJournalEvent(sequence: event.sequence, committedAtMs: event.committedAtMs, draft: reminder),
                projectsLifecycle: false))
        }
        let independentRequest = isAttention && context?.requestIdentity != nil && session.phase == .needsInput
        if !independentRequest && (draft.occurredAtMs < session.occurredAtMs
            || (draft.occurredAtMs == session.occurredAtMs && event.sequence < session.sequence)) {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        if draft.kind == .messagePublished {
            guard !session.ended else {
                session = originalSessionBeforeMove
                return .init(.stale)
            }
            guard context?.notification != nil else {
                return finalizeMovedDecision(.init(.observation))
            }
            let key = context?.requestIdentity ?? context?.eventIdentity ?? draft.eventId
            return finalizeMovedDecision(.init(
                .accepted,
                identity: Self.key([sessionKey, "message", key])
            ))
        }
        if (draft.kind == .turnCompleted || draft.kind == .idleObserved), let incomingTurn,
           let nativeTurn = session.nativeTurn, incomingTurn != nativeTurn {
            guard session.phase != .running, session.phase != .needsInput,
                  !session.seenTurns.contains(incomingTurn) else {
                session = originalSessionBeforeMove
                return .init(.stale)
            }
            session.turn = incomingTurn
            session.nativeTurn = incomingTurn
            session.completionIdentity = nil
            session.reopenedSinceCompletion = false
        }
        if draft.kind == .idleObserved {
            guard !draft.pendingWork, session.attentionIdentities.isEmpty, session.children.isEmpty,
                  session.phase == .idle || session.phase == .unknown,
                  !session.ended else {
                // Even a delayed idle observation commits a pane move so the
                // origin receipt invalidations cannot be lost on this early exit.
                return finalizeMovedDecision(.init(
                    .delayed,
                    projectsLifecycle: false
                ))
            }
            session.phase = .idle
            session.rootStopped = true
            session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
            session.sequence = max(session.sequence, event.sequence)
            storeSession(session, for: sessionKey, indexKey: boundaryKey)
            guard context?.notification != nil else {
                return .init(.observation, invalidatedCorrelationKeys: boundaryInvalidations)
            }
            // A structured idle reminder is a distinct presentation from the
            // completion that settled the turn. Keep the legacy completion
            // identity for generic idle observations, but admit one reminder
            // for the same settled turn so the banner can still be delivered
            // without reopening lifecycle attention.
            let identityKind = context?.notification?.category == "idle-reminder"
                ? "idle-reminder"
                : "completion"
            let identity: String
            if identityKind == "idle-reminder" {
                identity = Self.key([sessionKey, Self.key([
                    identityKind,
                    context?.turnIdentity ?? session.turn,
                    context?.requestIdentity ?? "",
                ])])
            } else {
                // Preserve the completion receipt shape for generic idle
                // observations and journal replay compatibility.
                identity = Self.key([sessionKey, Self.key([identityKind, context?.turnIdentity ?? session.turn])])
            }
            // The reminder repeats this turn's completion. Only the app knows
            // whether the user already read or dismissed it.
            let remindedCompletion = identityKind == "idle-reminder" && !session.reopenedSinceCompletion
                ? session.completionIdentity.flatMap { completion in
                    session.delivered[completion].map {
                        AgentNotificationDecision.RemindedCompletion(identity: completion, correlationKey: $0)
                    }
                }
                : nil
            session.delivered[identity] = context?.notification?.correlationKey ?? identity
            session.deliveredSurfaceIDs[identity] = draft.surfaceId
            if identityKind == "completion" {
                session.completionIdentity = identity
            }
            storeSession(session, for: sessionKey, indexKey: boundaryKey)
            return .init(
                .accepted,
                identity: identity,
                invalidatedCorrelationKeys: boundaryInvalidations,
                projectsLifecycle: context?.notification?.category != "idle-reminder",
                remindedCompletion: remindedCompletion
            )
        }
        if draft.kind == .turnStarted, let incomingTurn, incomingTurn == session.turn,
           session.phase == .needsInput || session.phase == .idle {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        if draft.kind == .turnStarted, let key = context?.eventIdentity,
           session.starts.contains(key) {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        if draft.kind == .turnCompleted, session.nativeTurn == nil, let incomingTurn {
            session.turn = incomingTurn
            session.nativeTurn = incomingTurn
        }
        if draft.kind == .turnCompleted, let key = context?.eventIdentity {
            if let boundTurn = session.completionTurns[key], boundTurn != session.turn {
                session = originalSessionBeforeMove
                return .init(.stale)
            }
            session.completionTurns[key] = session.turn
        }
        var invalidated: [String] = boundaryInvalidations
        if draft.kind == .turnStarted || draft.kind == .sessionEnded {
            invalidated.append(contentsOf: session.delivered.values)
            session.delivered.removeAll()
            session.deliveredSurfaceIDs.removeAll()
            session.attentionIdentities.removeAll()
            session.resolvedRequests.formUnion(session.attentionRequestIDs.values)
            session.attentionRequestIDs.removeAll()
            session.completionIdentity = nil
            session.reopenedSinceCompletion = false
            session.pendingCompletion = nil
        }
        let previousPhase = session.phase
        switch draft.kind {
        case .messagePublished, .attentionResolved, .idleObserved:
            return .init(.observation, invalidatedCorrelationKeys: invalidated)
        case .sessionStarted:
            if session.ended { session.phase = .unknown; session.nativeTurn = nil }
            session.ended = false
            session.superseded = false
            if draft.sessionStartOwnsSurface {
                sessionBoundaries[boundaryKey] = SessionBoundary(
                    sessionKey: sessionKey,
                    sequence: event.sequence
                )
            }
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
                for identity in Array(session.delivered.keys) where identity != session.completionIdentity {
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
                let isNewTurn = incomingTurn != nil
                    && incomingTurn != session.nativeTurn
                    && incomingTurn.map { !session.seenTurns.contains($0) } == true
                let isFreshIdentitylessActivity = incomingTurn == nil
                    && draft.nativeEvent?.caseInsensitiveCompare("PreToolUse") == .orderedSame
                    && (draft.occurredAtMs > session.occurredAtMs
                        || (draft.occurredAtMs == session.occurredAtMs && event.sequence > session.sequence))
                // A tool event without a turn identity is ambiguous after a
                // completion. Reopen only when its event timestamp/sequence is
                // newer than the completion watermark; this admits promptless
                // continuations while a late older event remains stale.
                guard session.phase != .idle || isNewTurn || isFreshIdentitylessActivity else { break }
                if isNewTurn, let incomingTurn {
                    session.turn = incomingTurn
                    session.nativeTurn = incomingTurn
                }
                session.rootStopped = false
                session.pendingCompletion = nil
                if session.completionIdentity != nil { session.reopenedSinceCompletion = true }
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
        storeSession(session, for: sessionKey, indexKey: boundaryKey)
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
            return .init(.observation, invalidatedCorrelationKeys: invalidated)
        }
        let identity = Self.key([sessionKey, boundary])
        session.delivered[identity] = context?.notification?.correlationKey ?? identity
        session.deliveredSurfaceIDs[identity] = draft.surfaceId
        if [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind) {
            session.attentionIdentities.insert(identity)
            if let request = context?.requestIdentity { session.attentionRequestIDs[identity] = request }
        }
        if draft.kind == .turnCompleted {
            // Re-asserting the same identity after a reopen keeps the flag: that
            // Stop's notification is deduplicated against the read completion.
            if session.completionIdentity != identity { session.reopenedSinceCompletion = false }
            session.completionIdentity = identity
        }
        storeSession(session, for: sessionKey, indexKey: boundaryKey)
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

    /// Names the bounded index and lifecycle boundary for one pane/agent pair.
    private static func surfaceAgentKey(surfaceID: String, agentKey: String) -> String {
        key([surfaceID, agentKey])
    }

    /// Persists a session and keeps the bounded surface index in sync.
    private mutating func storeSession(_ session: Session, for sessionKey: String, indexKey: String) {
        if let previous = sessions[sessionKey],
           let previousSurfaceID = previous.surfaceID,
           let previousAgentKey = previous.agentKey {
            let previousKey = Self.surfaceAgentKey(
                surfaceID: previousSurfaceID,
                agentKey: previousAgentKey
            )
            if previousKey != indexKey {
                sessionKeysBySurfaceAndAgent[previousKey]?.remove(sessionKey)
                if sessionKeysBySurfaceAndAgent[previousKey]?.isEmpty == true {
                    sessionKeysBySurfaceAndAgent.removeValue(forKey: previousKey)
                }
            }
        }
        if session.ended {
            sessionKeysBySurfaceAndAgent[indexKey]?.remove(sessionKey)
            if sessionKeysBySurfaceAndAgent[indexKey]?.isEmpty == true {
                sessionKeysBySurfaceAndAgent.removeValue(forKey: indexKey)
            }
        } else {
            sessionKeysBySurfaceAndAgent[indexKey, default: []].insert(sessionKey)
        }
        sessions[sessionKey] = session
    }
}
