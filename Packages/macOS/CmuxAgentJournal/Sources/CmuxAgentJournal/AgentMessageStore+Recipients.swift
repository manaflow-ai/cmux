import Foundation

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

    /// Turns messages for a surface or workspace off or on. Turning them off
    /// fails the recipient's queued messages, which are returned. Throws
    /// ``AgentMessagePersistenceError`` when the setting can't be saved, and
    /// then nothing changes.
    @discardableResult
    public func setReceivingEnabled(
        _ enabled: Bool,
        scope: AgentMessageRecipientScope,
        id: String
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
            applyRecipientSetting(enabled: enabled, scope: scope, id: id)
            // Toggling adds a record each time without adding a message, so
            // compact on the record count alone to keep the file bounded.
            if let fileURL, recordsSinceCompaction >= Self.compactionThreshold {
                compact(to: fileURL, force: true)
            }
        }
        return enabled ? [] : failBlockedQueued()
    }

    /// Fails every queued message whose recipient is blocked, including ones
    /// a wake hook has reserved but not yet acknowledged. Pass a surface to
    /// sweep only its messages. Returns the failed messages.
    @discardableResult
    public func failBlockedQueued(recipientSurfaceId: String? = nil) -> [AgentMessage] {
        var failed: [AgentMessage] = []
        lock.lock()
        let at = now()
        for id in order {
            guard var message = messagesById[id],
                  message.state == .queued,
                  recipientSurfaceId == nil || message.recipientSurfaceId == recipientSurfaceId,
                  let block = blockLocked(
                      recipientSurfaceId: message.recipientSurfaceId,
                      recipientWorkspaceId: message.recipientWorkspaceId
                  ) else { continue }
            Self.apply(state: .failed, at: at, via: nil, reason: block.reason, to: &message)
            messagesById[id] = message
            // Like other state records, best effort: a lost record replays
            // the message as queued, and the next sweep fails it again.
            if (try? appendRecord(Record(kind: .state, id: id, state: .failed, at: at, reason: block.reason))) != nil {
                recordsSinceCompaction += 1
            }
            failed.append(message)
        }
        lock.unlock()
        for message in failed {
            onChange?(AgentMessageStoreChange(message: message, state: .failed))
        }
        return failed
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

    /// Must hold `lock` (or run during `init`).
    func applyRecipientSetting(enabled: Bool, scope: AgentMessageRecipientScope, id: String) {
        let optOut = AgentMessageOptOut(scope: scope, id: id)
        optOutOrder.removeAll { $0 == optOut }
        setDisabled(!enabled, optOut)
        guard !enabled else { return }
        optOutOrder.append(optOut)
        while optOutOrder.count > Self.retainedOptOutCount {
            setDisabled(false, optOutOrder.removeFirst())
        }
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
