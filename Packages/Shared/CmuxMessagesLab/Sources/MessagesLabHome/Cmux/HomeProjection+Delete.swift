import CmuxHomeCore

/// Delete on my committed message in a Chief chat (https://github.com/manaflow-ai/cmux/issues/36019):
/// the row leaves at once (`deleting` shows the message retracted before the owner answers), the
/// owner retracts it (`message.retract`), and the Chief's memory writes the message over with its
/// tombstone when it hears the retraction (optchat-chief brain/inbox.rs). A refusal brings the row back.
extension HomeProjection {
    /// My committed, not retracted message in a one-to-one Chief chat (the owner retracts only its author's):
    /// a message I typed, not a run's read-only row, an agents row, a Feed row or an agent's send through my CLI.
    private func deletableMessage(_ message: ID) -> TranscriptItem? {
        guard isSendEnabled, shownSummary?.kind(me: me) == .chief,
              let item = shown.first(where: { HomeMapping.id($0, aliases: aliases) == message }),
              item.author == me, item.seq != nil, let canonical = item.messageID,
              !item.isRetracted, !item.isReadOnly, item.agentMessage == nil, item.feedRow == nil,
              HomeAgentSender(item, me: me) == nil, !deleting.contains(canonical) else { return nil }
        return item
    }

    func canDeleteMessage(_ message: ID) -> Bool { deletableMessage(message) != nil }

    func deleteMessage(_ message: ID) {
        guard let item = deletableMessage(message), let canonical = item.messageID else { return }
        deleting.insert(canonical)
        refresh()
        let intent = HomeIntent(op: .retractMessage(message: canonical, conversation: conversation))
        let homeStore = self.homeStore
        // task-owner: one op; ends with the owner's answer (a refusal shows the row again)
        Task { [weak self] in
            do {
                _ = try await homeStore.perform(intent.op, key: intent.key)
            } catch let rejection as HomeRejection {
                guard let self, !self.stopped else { return }
                self.deleting.remove(canonical)
                self.refresh()
                self.onRefusal(intent, rejection)
            } catch {
                guard let self, !self.stopped else { return }
                self.deleting.remove(canonical)
                self.refresh()
            }
        }
    }

    /// The store's items with the messages deleted here shown retracted until the owner's echo says so.
    /// A message whose retraction the store holds leaves `deleting`.
    func withDeletes(_ items: [TranscriptItem]) -> [TranscriptItem] {
        guard !deleting.isEmpty else { return items }
        for item in items where item.isRetracted {
            if let id = item.messageID { deleting.remove(id) }
        }
        return items.map { item in
            guard let id = item.messageID, deleting.contains(id), !item.isRetracted else { return item }
            var gone = item
            gone.isRetracted = true
            gone.parts = []
            gone.reactions = []
            return gone
        }
    }
}
