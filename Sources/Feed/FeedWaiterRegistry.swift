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
    private let groups = OSAllocatedUnfairLock(initialState: [String: Group]())

    func register(requestID: String, event: WorkstreamEvent) -> Registration? {
        let token = UUID()
        let semaphore = DispatchSemaphore(value: 0)
        return groups.withLock { groups in
            let existing = groups[requestID]
            if let existing, !Self.matches(existing.event, event) { return nil }
            var group = existing ?? Group(id: UUID(), event: event)
            group.subscribers[token] = semaphore
            groups[requestID] = group
            if group.terminalResult != nil || (group.itemID != nil && group.decision != nil) { semaphore.signal() }
            return Registration(requestID: requestID, groupID: group.id, token: token,
                semaphore: semaphore, isOwner: existing == nil)
        }
    }

    func accepted(_ registration: Registration, event: WorkstreamEvent, item: WorkstreamItem) {
        groups.withLock { groups in
            guard var group = groups[registration.requestID], group.id == registration.groupID else { return }
            group.event = event
            group.itemID = item.id
            if group.decision == nil {
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
            groups[registration.requestID] = group
            if group.decision != nil || group.terminalResult != nil {
                for semaphore in group.subscribers.values { semaphore.signal() }
            }
        }
    }

    /// Records a delivery failure unless the user already decided: a decision made
    /// in the store-commit gap outranks any later failure.
    func fail(_ registration: Registration, result: FeedCoordinator.IngestBlockingResult) {
        groups.withLock { groups in
            guard var group = groups[registration.requestID], group.id == registration.groupID else { return }
            guard group.decision == nil else { return }
            group.terminalResult = result
            group.replyStored = true
            groups[registration.requestID] = group
            for semaphore in group.subscribers.values { semaphore.signal() }
        }
    }

    func setAttention(_ target: FeedAttentionTarget, requestID: String) -> Bool {
        groups.withLock { groups in
            guard var group = groups[requestID], group.decision == nil, group.terminalResult == nil else { return false }
            group.target = target
            groups[requestID] = group
            return true
        }
    }

    func resolve(requestID: String, decision: WorkstreamDecision) -> Reply? {
        groups.withLock { groups in
            guard var group = groups[requestID], group.decision == nil, group.terminalResult == nil else { return nil }
            group.decision = decision
            let reply = Reply(requestID: requestID, groupID: group.id, event: group.event, target: group.target)
            group.target = nil
            groups[requestID] = group
            if group.itemID != nil { for semaphore in group.subscribers.values { semaphore.signal() } }
            return reply
        }
    }

    func replyStored(_ reply: Reply) {
        groups.withLock { groups in
            guard var group = groups[reply.requestID], group.id == reply.groupID else { return }
            group.replyStored = true
            if group.subscribers.isEmpty { groups.removeValue(forKey: reply.requestID) }
            else { groups[reply.requestID] = group }
        }
    }

    func finish(_ registration: Registration) -> Finished {
        groups.withLock { groups in
            guard var group = groups[registration.requestID], group.id == registration.groupID else {
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
                groups.removeValue(forKey: registration.requestID)
            } else {
                groups[registration.requestID] = group
            }
            return Finished(outcome: .init(result: result, authoritativeEvent: group.event),
                target: target, shouldCancel: cancel, itemID: group.itemID)
        }
    }

    func cleanupStored(requestID: String, groupID: UUID) {
        groups.withLock { groups in
            guard var group = groups[requestID], group.id == groupID else { return }
            group.replyStored = true
            if group.subscribers.isEmpty { groups.removeValue(forKey: requestID) }
            else { groups[requestID] = group }
        }
    }

    func invalidate(requestID: String, source: String, sessionID: String) -> (Reply, UUID?)? {
        groups.withLock { groups in
            guard var group = groups[requestID], group.decision == nil, !group.cleanupClaimed,
                  group.event.source == source else { return nil }
            let canonical = FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: source, rawValue: group.event.sessionId)
            guard (FeedWorkstreamIdentifier(rawValue: canonical)?.sessionID ?? group.event.sessionId) == sessionID else { return nil }
            let reply = Reply(requestID: requestID, groupID: group.id, event: group.event, target: group.target)
            group.target = nil
            group.cleanupClaimed = true
            group.terminalResult = .unavailable
            groups[requestID] = group
            for semaphore in group.subscribers.values { semaphore.signal() }
            return (reply, group.itemID)
        }
    }

    func isAwaiting(_ requestID: String) -> Bool {
        groups.withLock { groups in
            guard let group = groups[requestID] else { return false }
            return group.decision == nil && group.terminalResult == nil && !group.subscribers.isEmpty
        }
    }

    func liveRequestIDs() -> Set<String> {
        groups.withLock { Set($0.compactMap { key, group in
            group.decision == nil && group.terminalResult == nil ? key : nil
        }) }
    }

    func discardInactive() {
        groups.withLock { $0 = $0.filter { !$0.value.subscribers.isEmpty } }
    }

    func subscriberCount(_ requestID: String) -> Int { groups.withLock { $0[requestID]?.subscribers.count ?? 0 } }

    private static func matches(_ lhs: WorkstreamEvent, _ rhs: WorkstreamEvent) -> Bool {
        lhs.source == rhs.source
            && FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: lhs.source, rawValue: lhs.sessionId)
                == FeedWorkstreamIdentifier.canonicalizedRawValue(agentID: rhs.source, rawValue: rhs.sessionId)
            && lhs.hookEventName == rhs.hookEventName && lhs.toolName == rhs.toolName
            && lhs.cwd == rhs.cwd && (lhs.toolInputJSON ?? "{}") == (rhs.toolInputJSON ?? "{}")
    }
}
