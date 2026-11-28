import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import os

/// One pending request owns its reply and attention, even when several hooks retry it.
final class FeedWaiterRegistry: Sendable {
    struct Registration: Sendable {
        let requestID: String
        let groupID: UUID
        let token: UUID
        let semaphore: DispatchSemaphore
        let isOwner: Bool
    }
    struct Reply: Sendable {
        let requestID: String
        let groupID: UUID
        let event: WorkstreamEvent
        let target: FeedAttentionTarget?
    }
    struct Finished: Sendable {
        let outcome: FeedCoordinator.IngestBlockingOutcome
        let target: FeedAttentionTarget?
        let shouldCancel: Bool
        let itemID: UUID?
    }
    private struct Group: Sendable {
        let id: UUID
        var event: WorkstreamEvent
        var subscribers: [UUID: DispatchSemaphore] = [:]
        var itemID: UUID?
        var decision: WorkstreamDecision?
        var terminalResult: FeedCoordinator.IngestBlockingResult?
        var target: FeedAttentionTarget?
        var replyStored = false
        var cleanupClaimed = false
    }
    struct Superseded: Sendable {
        var pending: [(Reply, UUID?)] = []
        var handedOff: [(requestID: String, event: WorkstreamEvent)] = []
    }
    private struct State: Sendable {
        var groups: [String: Group] = [:]
        /// Requests nobody answered in cmux before the hook timed out. The
        /// hook hands those back to the agent's own prompt, so they stay here
        /// until a later hook from the same agent shows they were answered
        /// there. They sit under the same lock as `groups`, so a group's
        /// timeout and its handoff are one step for every other operation.
        var handedOff: [String: WorkstreamEvent] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(requestID: String, event: WorkstreamEvent) -> Registration? {
        let token = UUID()
        let semaphore = DispatchSemaphore(value: 0)
        return state.withLock { state in
            let existing = state.groups[requestID]
            if let existing, !Self.matches(existing.event, event) { return nil }
            // A retry that starts a new group owns the request again. One that
            // joins the timed-out group before its cleanup gets that timeout.
            if existing == nil { state.handedOff.removeValue(forKey: requestID) }
            var group = existing ?? Group(id: UUID(), event: event)
            group.subscribers[token] = semaphore
            state.groups[requestID] = group
            if group.terminalResult != nil || (group.itemID != nil && group.decision != nil) { semaphore.signal() }
            return Registration(requestID: requestID, groupID: group.id, token: token,
                semaphore: semaphore, isOwner: existing == nil)
        }
    }

    func accepted(_ registration: Registration, event: WorkstreamEvent, item: WorkstreamItem) {
        state.withLock { state in
            guard var group = state.groups[registration.requestID], group.id == registration.groupID else { return }
            group.event = event
            group.itemID = item.id
            if group.decision == nil, group.terminalResult == nil {
                switch item.status {
                case .resolved:
                    // A handled retry is a no-op; never grant permission again from history.
                    group.terminalResult = .acknowledged(itemId: item.id)
                    group.replyStored = true
                case .expired:
                    group.terminalResult = .timedOut(itemId: item.id)
                    group.replyStored = true
                default: break
                }
            }
            state.groups[registration.requestID] = group
            if group.decision != nil || group.terminalResult != nil {
                for semaphore in group.subscribers.values { semaphore.signal() }
            }
        }
    }

    /// Records the first terminal delivery outcome. A user decision or an earlier
    /// terminal result, including session invalidation, outranks any later failure.
    func fail(_ registration: Registration, result: FeedCoordinator.IngestBlockingResult) {
        state.withLock { state in
            guard var group = state.groups[registration.requestID], group.id == registration.groupID else { return }
            guard group.decision == nil, group.terminalResult == nil else { return }
            group.terminalResult = result
            group.replyStored = true
            state.groups[registration.requestID] = group
            for semaphore in group.subscribers.values { semaphore.signal() }
        }
    }

    func setAttention(_ target: FeedAttentionTarget, requestID: String) -> Bool {
        state.withLock { state in
            guard var group = state.groups[requestID], group.decision == nil, group.terminalResult == nil else { return false }
            group.target = target
            state.groups[requestID] = group
            return true
        }
    }

    func resolve(requestID: String, decision: WorkstreamDecision) -> Reply? {
        state.withLock { state in
            guard var group = state.groups[requestID], group.decision == nil, group.terminalResult == nil else { return nil }
            group.decision = decision
            let reply = Reply(requestID: requestID, groupID: group.id, event: group.event, target: group.target)
            group.target = nil
            state.groups[requestID] = group
            if group.itemID != nil { for semaphore in group.subscribers.values { semaphore.signal() } }
            return reply
        }
    }

    func replyStored(_ reply: Reply) {
        state.withLock { state in
            guard var group = state.groups[reply.requestID], group.id == reply.groupID else { return }
            group.replyStored = true
            if group.subscribers.isEmpty { state.groups.removeValue(forKey: reply.requestID) }
            else { state.groups[reply.requestID] = group }
        }
    }

    func finish(_ registration: Registration) -> Finished {
        state.withLock { state in
            guard var group = state.groups[registration.requestID], group.id == registration.groupID else {
                return Finished(outcome: .init(result: .unavailable, authoritativeEvent: nil),
                    target: nil, shouldCancel: false, itemID: nil)
            }
            group.subscribers.removeValue(forKey: registration.token)
            let result: FeedCoordinator.IngestBlockingResult
            if let terminal = group.terminalResult { result = terminal }
            else if let decision = group.decision { result = .resolved(itemId: group.itemID, decision: decision) }
            else { result = .timedOut(itemId: group.itemID) }
            let cancel = group.subscribers.isEmpty && group.decision == nil && !group.cleanupClaimed
            let target = cancel ? group.target : nil
            if cancel {
                group.cleanupClaimed = true
                group.replyStored = false
                group.terminalResult = result
                group.target = nil
            }
            if group.subscribers.isEmpty && group.replyStored {
                state.groups.removeValue(forKey: registration.requestID)
            } else {
                state.groups[registration.requestID] = group
            }
            // Only a stamped request can later be shown superseded.
            if cancel, case .timedOut = result, group.event.feedHookSentAtMs != nil {
                state.handedOff[registration.requestID] = group.event
            }
            return Finished(outcome: .init(result: result, authoritativeEvent: group.event),
                target: target, shouldCancel: cancel, itemID: group.itemID)
        }
    }

    func cleanupStored(requestID: String, groupID: UUID) {
        state.withLock { state in
            guard var group = state.groups[requestID], group.id == groupID else { return }
            group.replyStored = true
            if group.subscribers.isEmpty { state.groups.removeValue(forKey: requestID) }
            else { state.groups[requestID] = group }
        }
    }

    func invalidate(requestID: String, source: String, sessionID: String) -> (Reply, UUID?)? {
        state.withLock { state in
            if let event = state.handedOff[requestID], Self.belongs(event, source: source, sessionID: sessionID) {
                state.handedOff.removeValue(forKey: requestID)
            }
            guard var group = state.groups[requestID], group.decision == nil, !group.cleanupClaimed,
                  group.event.source == source else { return nil }
            let canonical = FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: source, rawValue: group.event.sessionId)
            guard (FeedWorkstreamIdentifier(rawValue: canonical)?.sessionID ?? group.event.sessionId) == sessionID else { return nil }
            let reply = Reply(requestID: requestID, groupID: group.id, event: group.event, target: group.target)
            group.target = nil
            group.cleanupClaimed = true
            group.terminalResult = .unavailable
            state.groups[requestID] = group
            for semaphore in group.subscribers.values { semaphore.signal() }
            return (reply, group.itemID)
        }
    }

    /// Invalidates every undecided request belonging to one agent session.
    /// Surface teardown can be the only terminal signal when the agent died
    /// before its SessionEnd hook ran, so cleanup cannot depend on knowing the
    /// individual request ids that were pending on that session.
    func invalidate(source: String, sessionID: String) -> [(Reply, UUID?)] {
        state.withLock { state in
            state.handedOff = state.handedOff.filter { !Self.belongs($0.value, source: source, sessionID: sessionID) }
            var invalidated: [(Reply, UUID?)] = []
            for (requestID, var group) in state.groups {
                guard group.decision == nil, group.terminalResult == nil,
                      !group.cleanupClaimed,
                      Self.belongs(group.event, source: source, sessionID: sessionID) else { continue }
                invalidated.append((Reply(requestID: requestID, groupID: group.id,
                    event: group.event, target: group.target), group.itemID))
                group.target = nil
                group.cleanupClaimed = true
                group.terminalResult = .unavailable
                state.groups[requestID] = group
                for semaphore in group.subscribers.values { semaphore.signal() }
            }
            return invalidated
        }
    }

    /// Retires every undecided request the agent provably moved past: one from
    /// the same agent context (source, session, and subagent) whose hook was
    /// sent before `event`. Requests or events without a send stamp never match.
    /// With `retiringHandedOff`, the timed-out requests `event` shows were
    /// answered in the agent's own prompt are taken by the same rule, under the
    /// same lock, so a retry cannot register between the two.
    func supersede(by event: WorkstreamEvent, retiringHandedOff: Bool = true) -> Superseded {
        guard event.feedHookSentAtMs != nil else { return Superseded() }
        return state.withLock { state in
            var superseded = Superseded()
            for (requestID, var group) in state.groups {
                guard group.decision == nil, group.terminalResult == nil, !group.cleanupClaimed,
                      Self.isSuperseded(group.event, by: event) else { continue }
                superseded.pending.append((Reply(requestID: requestID, groupID: group.id, event: group.event,
                    target: group.target), group.itemID))
                group.target = nil
                group.cleanupClaimed = true
                group.terminalResult = .unavailable
                state.groups[requestID] = group
                for semaphore in group.subscribers.values { semaphore.signal() }
            }
            guard retiringHandedOff else { return superseded }
            for (requestID, request) in state.handedOff where Self.isSuperseded(request, by: event) {
                state.handedOff.removeValue(forKey: requestID)
                superseded.handedOff.append((requestID: requestID, event: request))
            }
            return superseded
        }
    }

    func isAwaiting(_ requestID: String) -> Bool {
        state.withLock { state in
            guard let group = state.groups[requestID] else { return false }
            return group.decision == nil && group.terminalResult == nil && !group.subscribers.isEmpty
        }
    }

    func liveRequestIDs() -> Set<String> {
        state.withLock { Set($0.groups.compactMap { key, group in
            group.decision == nil && group.terminalResult == nil ? key : nil
        }) }
    }

    func discardInactive() {
        state.withLock { state in
            state.groups = state.groups.filter { !$0.value.subscribers.isEmpty }
            state.handedOff.removeAll()
        }
    }

    func subscriberCount(_ requestID: String) -> Int { state.withLock { $0.groups[requestID]?.subscribers.count ?? 0 } }

    /// A request is superseded by a hook from the same agent context (source,
    /// session, and subagent) sent after it. Unstamped events never match.
    private static func isSuperseded(_ request: WorkstreamEvent, by event: WorkstreamEvent) -> Bool {
        guard let observedAtMs = event.feedHookSentAtMs,
              let requestedAtMs = request.feedHookSentAtMs,
              requestedAtMs < observedAtMs else { return false }
        return request.source == event.source
            && FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: request.source, rawValue: request.sessionId)
                == FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: event.source, rawValue: event.sessionId)
            && request.feedAgentID == event.feedAgentID
    }

    private static func belongs(_ event: WorkstreamEvent, source: String, sessionID: String) -> Bool {
        guard event.source == source else { return false }
        let canonical = FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: source, rawValue: event.sessionId)
        return (FeedWorkstreamIdentifier(rawValue: canonical)?.sessionID ?? event.sessionId) == sessionID
    }

    private static func matches(_ lhs: WorkstreamEvent, _ rhs: WorkstreamEvent) -> Bool {
        lhs.source == rhs.source
            && FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: lhs.source, rawValue: lhs.sessionId)
                == FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: rhs.source, rawValue: rhs.sessionId)
            && lhs.hookEventName == rhs.hookEventName && lhs.toolName == rhs.toolName
            && lhs.cwd == rhs.cwd && (lhs.toolInputJSON ?? "{}") == (rhs.toolInputJSON ?? "{}")
    }
}
