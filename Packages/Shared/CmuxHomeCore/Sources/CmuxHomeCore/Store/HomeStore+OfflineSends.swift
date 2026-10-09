import Foundation

// HomeStore's sends made while the owner is gone (Messages parity): the
// send waits as "sending" and goes under its key at the reconnect; it fails
// "Not Delivered" only when the owner stays gone past the deadline.
extension HomeStore {
    /// How long a send made while the owner is gone waits for it to come
    /// back before it fails "Not Delivered" (a tap sends it again): the
    /// same total as the resends of a send that got no answer.
    public static var offlineSendDeadline: Duration { resendBackoff.reduce(.zero, +) }

    /// Logs a send made while offline or connecting (the Chief owner or its
    /// brain restarting, a build reconnecting) instead of refusing it. It
    /// is unconfirmed, so the reconnect sends it with the other resends, in
    /// order, and later sends wait behind it. Always throws: `pendingResend`
    /// once logged.
    func queueWhileOffline(_ intent: HomeIntent, in conversation: ConversationID) throws -> Never {
        guard log.append(intent) else { throw HomeRejection.invalid("duplicate intent") }
        log.markUnconfirmed(intent.key)
        offlineQueued.insert(intent.key)
        enqueueSend(intent.key, in: conversation)
        afterLogChange(intent.op)
        scheduleOfflineDeadline(intent.key)
        throw HomeSendState.pendingResend
    }

    /// The same for a logged send with attachments: its uploads wait for
    /// the reconnect (`resumeInterruptedUploads`, in log order), then it
    /// goes after every earlier send of its conversation. Always throws
    /// `pendingResend`.
    func queueUploadWhileOffline(_ key: IdempotencyKey) throws -> Never {
        uploads[key]?.waitingForReconnect = true
        offlineQueued.insert(key)
        scheduleOfflineDeadline(key)
        throw HomeSendState.pendingResend
    }

    /// Fails the send "Not Delivered" when it is still waiting for the
    /// owner at the deadline: unanswered, or its uploads waiting for the
    /// reconnect. A send in flight or committed by then is decided by its
    /// answer instead.
    private func scheduleOfflineDeadline(_ key: IdempotencyKey) {
        let clock = self.clock
        let deadline = Self.offlineSendDeadline
        offlineDeadlines[key]?.cancel()
        offlineDeadlines[key] = Task { [weak self] in
            do { try await clock.sleep(for: deadline) } catch { return }
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.offlineDeadlines[key] = nil
            guard let entry = self.log.entries.first(where: { $0.intent.key == key }) else { return }
            let uploadWaiting = self.uploads[key]?.waitingForReconnect == true
            guard entry.state == .unconfirmed || uploadWaiting else { return }
            // Never sent: "Not Delivered". Sent once and unanswered since:
            // the owner may have committed it.
            let reachedOwner = self.uploads[key]?.reachedOwner ?? !self.offlineQueued.contains(key)
            self.offlineQueued.remove(key)
            self.giveUp(key, .ownerUnreachable, reachedOwner: reachedOwner)
        }
    }

    /// The send goes to the owner now: it is no longer only queued.
    func noteSubmitted(_ key: IdempotencyKey) {
        offlineQueued.remove(key)
    }

    /// The owner decided the send (or it left the log): its deadline ends.
    func endOfflineDeadline(_ key: IdempotencyKey) {
        offlineQueued.remove(key)
        offlineDeadlines.removeValue(forKey: key)?.cancel()
    }

    func cancelOfflineDeadlines() {
        for task in offlineDeadlines.values { task.cancel() }
        offlineDeadlines.removeAll()
        offlineQueued.removeAll()
    }
}
