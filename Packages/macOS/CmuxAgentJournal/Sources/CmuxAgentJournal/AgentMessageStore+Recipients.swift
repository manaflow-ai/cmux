import Foundation
internal import os

private let optOutLogger = Logger(subsystem: "com.cmuxterm.app", category: "AgentMessages")

/// The off switches: the app-wide `isEnabled` closure and per-surface or
/// per-workspace opt-outs kept in the journal.
///
/// A blocked recipient gets nothing new (``append(_:)`` throws
/// ``AgentMessageBlockedError``) and its queued messages move to
/// ``AgentMessageDeliveryState/failed`` with the block's reason, so nothing
/// stays queued for a recipient that turned messages off.
extension AgentMessageStore {
    /// Why messages to the recipient are off, or `nil` when they are on.
    public func block(recipientSurfaceId: String, recipientWorkspaceId: String?) -> AgentMessageBlock? {
        lock.lock()
        defer { lock.unlock() }
        return blockLocked(recipientSurfaceId: recipientSurfaceId, recipientWorkspaceId: recipientWorkspaceId)
    }

    /// True when the surface or workspace turned messages off. Ignores the
    /// app-wide switch.
    public func isReceivingDisabled(scope: AgentMessageRecipientScope, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch scope {
        case .surface: return disabledSurfaceIds.contains(id)
        case .workspace: return disabledWorkspaceIds.contains(id)
        }
    }

    /// True when one more opt-out would push one out. Callers check it to
    /// decide whether to gather ``AgentMessageOpenRecipients``.
    public var isAtOptOutCapacity: Bool {
        lock.withLock { optOutOrder.count >= Self.retainedOptOutCount }
    }

    /// Turns messages for a surface or workspace off or on. Turning them off
    /// fails the recipient's queued messages, which are returned. Throws
    /// ``AgentMessagePersistenceError`` when the setting can't be saved, and
    /// then nothing changes.
    ///
    /// Past ``retainedOptOutCount`` one opt-out is dropped, which turns
    /// messages back on for it. With `openRecipients`, the oldest opt-out for
    /// a surface or workspace that is no longer open goes first; only when
    /// every one is still open does the oldest go.
    @discardableResult
    public func setReceivingEnabled(
        _ enabled: Bool,
        scope: AgentMessageRecipientScope,
        id: String,
        openRecipients: AgentMessageOpenRecipients? = nil
    ) throws -> [AgentMessage] {
        try lock.withLock {
            let current: Bool
            switch scope {
            case .surface: current = !disabledSurfaceIds.contains(id)
            case .workspace: current = !disabledWorkspaceIds.contains(id)
            }
            guard current != enabled else { return }
            do {
                try appendRecord(Record(kind: .recipient, id: id, at: now(), scope: scope, enabled: enabled))
            } catch {
                throw AgentMessagePersistenceError(reason: String(describing: error))
            }
            recordsSinceCompaction += 1
            for evicted in applyRecipientSetting(enabled: enabled, scope: scope, id: id, openRecipients: openRecipients) {
                // Record the eviction so replay drops the same opt-out. Best
                // effort: a lost record leaves replay to drop the oldest.
                if (try? appendRecord(Record(kind: .recipient, id: evicted.id, at: now(), scope: evicted.scope, enabled: true))) != nil {
                    recordsSinceCompaction += 1
                }
                let openState = openRecipients.map { $0.contains(evicted) ? "open" : "closed" } ?? "unknown"
                optOutLogger.notice(
                    "agent message opt-out cap reached; dropped \(evicted.scope.rawValue, privacy: .public) \(evicted.id, privacy: .public) (\(openState, privacy: .public))"
                )
            }
            // Toggling adds a record each time without adding a message, so
            // compact on the record count alone to keep the file bounded.
            if let fileURL, recordsSinceCompaction >= Self.compactionThreshold {
                compact(to: fileURL, force: true)
            }
        }
        return enabled ? [] : failBlockedQueued()
    }

    /// Fails every queued message whose recipient is blocked. Pass a surface
    /// to sweep only its messages. Returns the failed messages.
    ///
    /// Messages on a live wake-hook lease are skipped: the hook has already
    /// shown them to the agent, so its acknowledgement records them
    /// delivered. If the lease expires unacknowledged, the next sweep or
    /// claim fails them.
    @discardableResult
    public func failBlockedQueued(recipientSurfaceId: String? = nil) -> [AgentMessage] {
        var failed: [AgentMessage] = []
        lock.lock()
        pruneExpiredDeferredLeases()
        let at = now()
        for id in order {
            guard let message = messagesById[id],
                  message.state == .queued,
                  recipientSurfaceId == nil || message.recipientSurfaceId == recipientSurfaceId,
                  !isDeferredMessageReserved(id),
                  let block = blockLocked(
                      recipientSurfaceId: message.recipientSurfaceId,
                      recipientWorkspaceId: message.recipientWorkspaceId
                  ) else { continue }
            failed.append(failLocked(id: id, block: block, at: at))
        }
        lock.unlock()
        publish(failed, as: .failed)
        return failed
    }

    /// Moves one queued message to `failed`. Must hold `lock`; the caller
    /// publishes the change after unlocking.
    func failLocked(id: String, block: AgentMessageBlock, at: Date) -> AgentMessage {
        guard var message = messagesById[id] else { preconditionFailure("unknown message \(id)") }
        Self.apply(state: .failed, at: at, via: nil, reason: block.reason, to: &message)
        messagesById[id] = message
        // Like other state records, best effort: a lost record replays the
        // message as queued, and the next sweep or claim fails it again.
        if (try? appendRecord(Record(kind: .state, id: id, state: .failed, at: at, reason: block.reason))) != nil {
            recordsSinceCompaction += 1
        }
        return message
    }

    /// Must hold `lock`.
    func blockLocked(recipientSurfaceId: String, recipientWorkspaceId: String?) -> AgentMessageBlock? {
        if !isEnabled() {
            return .messagesDisabled
        }
        if disabledSurfaceIds.contains(recipientSurfaceId) {
            return .recipientDisabled(surfaceId: recipientSurfaceId)
        }
        if let recipientWorkspaceId, disabledWorkspaceIds.contains(recipientWorkspaceId) {
            return .workspaceDisabled(workspaceId: recipientWorkspaceId)
        }
        return nil
    }

    /// Applies one setting and returns the opt-outs the cap dropped. Must
    /// hold `lock` (or run during `init`). Replay passes `capping: false`
    /// and trims once at the end, because a live drop is written after the
    /// opt-out that caused it.
    @discardableResult
    func applyRecipientSetting(
        enabled: Bool,
        scope: AgentMessageRecipientScope,
        id: String,
        openRecipients: AgentMessageOpenRecipients? = nil,
        capping: Bool = true
    ) -> [AgentMessageOptOut] {
        let optOut = AgentMessageOptOut(scope: scope, id: id)
        optOutOrder.removeAll { $0 == optOut }
        setDisabled(!enabled, optOut)
        guard !enabled else { return [] }
        optOutOrder.append(optOut)
        return capping ? trimOptOuts(openRecipients: openRecipients) : []
    }

    /// Drops opt-outs past ``retainedOptOutCount``. Must hold `lock`.
    @discardableResult
    func trimOptOuts(openRecipients: AgentMessageOpenRecipients? = nil) -> [AgentMessageOptOut] {
        var evicted: [AgentMessageOptOut] = []
        while optOutOrder.count > Self.retainedOptOutCount {
            // Never the one just added, which is last.
            let closed = openRecipients.flatMap { open in
                optOutOrder.dropLast().firstIndex { !open.contains($0) }
            }
            let dropped = optOutOrder.remove(at: closed ?? 0)
            setDisabled(false, dropped)
            evicted.append(dropped)
        }
        return evicted
    }

    private func setDisabled(_ disabled: Bool, _ optOut: AgentMessageOptOut) {
        switch (optOut.scope, disabled) {
        case (.surface, false): _ = disabledSurfaceIds.remove(optOut.id)
        case (.surface, true): _ = disabledSurfaceIds.insert(optOut.id)
        case (.workspace, false): _ = disabledWorkspaceIds.remove(optOut.id)
        case (.workspace, true): _ = disabledWorkspaceIds.insert(optOut.id)
        }
    }
}

/// One stored opt-out.
struct AgentMessageOptOut: Equatable, Sendable {
    let scope: AgentMessageRecipientScope
    let id: String
}

/// The surfaces and workspaces open right now, used to pick which opt-out
/// to drop when the store is full.
public struct AgentMessageOpenRecipients: Sendable, Equatable {
    public var surfaceIds: Set<String>
    public var workspaceIds: Set<String>

    public init(surfaceIds: Set<String>, workspaceIds: Set<String>) {
        self.surfaceIds = surfaceIds
        self.workspaceIds = workspaceIds
    }

    func contains(_ optOut: AgentMessageOptOut) -> Bool {
        switch optOut.scope {
        case .surface: return surfaceIds.contains(optOut.id)
        case .workspace: return workspaceIds.contains(optOut.id)
        }
    }
}
