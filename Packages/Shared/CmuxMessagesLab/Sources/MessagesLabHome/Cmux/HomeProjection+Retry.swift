import CmuxHomeCore

/// Try Again and Delete on my "Not Delivered" message (the transcript's context menu): the send
/// goes again through `HomeStore.retry` (same key when the owner may have it, else a new one) or
/// leaves through `HomeStore.discardFailed`. HomeStore decides the row; the projection follows.
extension HomeProjection {
    /// My send that the owner did not take.
    private func failedSend(_ message: ID) -> TranscriptItem? {
        guard let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == message }),
              item.seq == nil, item.author == me, case .notDelivered = item.delivery else { return nil }
        return item
    }

    func canRetrySend(_ message: ID) -> Bool { failedSend(message) != nil }

    func retrySend(_ message: ID) {
        guard let item = failedSend(message) else { return }
        let homeStore = self.homeStore
        // task-owner: one retry; ends with the owner's answer (a refusal leaves the row Not Delivered)
        Task { try? await homeStore.retry(item.key) }
    }

    /// A committed person message in a one-to-one Chief conversation. The
    /// owner's canonical message id is required: pending local sends have no
    /// owner id and are handled by `canRetrySend` instead.
    private func chiefTurnMessage(_ message: ID) -> TranscriptItem? {
        guard shownSummary?.kind(me: me) == .chief,
              let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == message }),
              item.author == me, item.seq != nil, item.messageID != nil,
              item.isRetracted == false else { return nil }
        return item
    }

    func canRetryChiefTurn(_ message: ID) -> Bool {
        onChiefRetry != nil && homeStore.typists(in: conversation).isEmpty && chiefTurnMessage(message) != nil
    }

    func retryChiefTurn(_ message: ID) {
        guard let item = chiefTurnMessage(message), let canonical = item.messageID else { return }
        onChiefRetry?(canonical)
    }

    var canForward: Bool { onForward != nil }

    func forward(_ text: String) { onForward?(text) }

    func deleteFailedSend(_ message: ID) {
        guard let item = failedSend(message) else { return }
        homeStore.discardFailed(item.key)
    }
}
