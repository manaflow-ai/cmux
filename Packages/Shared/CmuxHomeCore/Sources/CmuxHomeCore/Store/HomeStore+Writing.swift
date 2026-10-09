import Foundation

// HomeStore's write path: perform, retry, cancel, discard, read cursors,
// search and contact resolution.
extension HomeStore {
    // MARK: Writing

    /// Sends an intent to its owner. While offline or connecting a
    /// `sendMessage` waits for the reconnect (Messages parity, see
    /// `offlineSendDeadline`) and throws `HomeSendState.pendingResend`;
    /// any other op is refused at once. Throws `HomeRejection` when
    /// refused, and `HomeSendState.pendingResend` when the answer was lost
    /// and the store resends it with the same key. A `sendMessage` goes to
    /// the owner only after every earlier send in its conversation was
    /// decided (see `sendQueue`), so a burst of sends commits in the order made.
    @discardableResult
    public func perform(_ op: HomeOp, key: IdempotencyKey = .make()) async throws -> HomeOpResult {
        guard !stopped else { throw HomeRejection.ownerUnreachable }
        guard isOnline else {
            if case .sendMessage(let conversation, _) = op {
                try queueWhileOffline(HomeIntent(key: key, op: op), in: conversation)
            }
            throw HomeRejection.ownerUnreachable
        }
        if case .setTyping = op {
            // Ephemeral: no intent, nothing to settle or resend.
            do {
                return try await source.submit(HomeIntent(key: key, op: op))
            } catch is HomeOwnerOffline {
                throw HomeRejection.ownerUnreachable
            }
        }
        let intent = HomeIntent(key: key, op: op)
        guard log.append(intent) else { throw HomeRejection.invalid("duplicate intent") }
        afterLogChange(op)
        if case .sendMessage(let conversation, _) = op {
            enqueueSend(key, in: conversation)
            await waitForTurn(key, in: conversation)
            // Cancelled or dropped while it waited.
            guard log.entries.contains(where: { $0.intent.key == key }), !stopped else { throw CancellationError() }
        }
        return try await submit(intent)
    }

    /// Retries a "Not Delivered" send. A send that went to the owner and
    /// got no answer (`indeterminate`, `ownerUnreachable`) goes again under
    /// the same key: the owner may have committed it, and its ledger
    /// replays that commit. A send whose attachment upload failed never
    /// reached the owner: it keeps its key (and its row) and uploads only
    /// the missing attachments. A send with attachments that the owner
    /// refused keeps its row position under a new key (the owner's ledger
    /// keeps the refused one) and uploads every attachment again first: an
    /// upload the owner still holds answers `exists` without sending the
    /// bytes. A same-key retry that gets `unknown_attachment` uploads again
    /// by itself, once, and throws `HomeSendState.pendingResend`. Another
    /// refused op is sent again as a new intent.
    public func retry(_ key: IdempotencyKey) async throws {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .failed(let rejection) = entry.state else { return }
        backoffAttempts[key] = nil
        uploads[key]?.resumedImmediately = false
        uploads[key]?.uploadedAfterSweep = false
        // Sent, but never answered: the owner may have committed it, so it
        // goes again under the same key (the owner's ledger replays it).
        if rejection == .indeterminate || rejection == .ownerUnreachable, uploads[key]?.reachedOwner ?? true {
            log.revive(key)
            if case .sendMessage(let conversation, _) = entry.intent.op {
                enqueueSend(key, in: conversation)
                afterLogChange(entry.intent.op)
                await waitForTurn(key, in: conversation)
                guard log.entries.contains(where: { $0.intent.key == key }), !stopped else { throw CancellationError() }
            }
            _ = try await submit(entry.intent)
            return
        }
        if let job = uploads[key] {
            var target = key
            if job.reachedOwner {
                target = .make()
                restartUploads(from: key, as: target)
            } else {
                log.setUploading(key, true)
            }
            enqueueSend(target, in: job.conversation)
            afterLogChange(entry.intent.op)
            try await uploadAndSubmit(target)
            return
        }
        log.discard(key)
        afterLogChange(entry.intent.op)
        try await perform(entry.intent.op)
    }

    /// Cancels a send the owner has not decided: stops its uploads (the
    /// source's upload task is cancelled), drops the row and makes the
    /// pending `send` or `perform` throw `CancellationError`. Works for an
    /// upload in flight or waiting for a reconnect, a send queued behind
    /// an earlier one or waiting for the owner to come back, and a "Not
    /// Delivered" send. Returns false when there is nothing to cancel: an
    /// unknown key, or a send in flight to the owner or unanswered (it
    /// commits, or fails after its resends).
    @discardableResult
    public func cancelSend(_ key: IdempotencyKey) -> Bool {
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .sendMessage = entry.intent.op else { return false }
        let failed = if case .failed = entry.state { true } else { false }
        let waitingForOwner = offlineQueued.contains(key)
        guard entry.isUploading || entry.isQueued || failed || waitingForOwner else { return false }
        endOfflineDeadline(key)
        uploads[key]?.task?.cancel()
        uploads[key] = nil
        cancelBackoff(key)
        pendingResends.removeAll { $0.key == key }
        log.discard(key)
        afterLogChange(entry.intent.op)
        return true
    }

    public func discardFailed(_ key: IdempotencyKey) {
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .failed = entry.state else { return }
        log.discard(key)
        uploads[key] = nil
        afterLogChange(entry.intent.op)
    }

    /// Marks everything up to the newest message as read (once per seq:
    /// the visible cursor already includes a pending cursor intent).
    public func markRead(_ id: ConversationID) {
        guard isOnline, let me = me?.id, let summary = mirror.conversations[id] else { return }
        let visible = rows.first { $0.id == id }?.summary.readCursors[me] ?? summary.readCursors[me] ?? 0
        guard summary.lastSeq > visible else { return }
        Task { try? await self.perform(.setReadCursor(conversation: id, seq: summary.lastSeq)) }
    }

    public func search(_ query: String, limit: Int = 50) async throws -> [HomeSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await source.search(trimmed, limit: limit)
    }

    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        try await source.resolve(contact)
    }
}
