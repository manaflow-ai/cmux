import Foundation

// A Chief's live run frames (`chief-live-v1`) through HomeLiveBook into
// `live`, the one value every Home view draws.
extension HomeStore {
    func applyLive(_ event: HomeLiveEvent) {
        let conversation = event.conversation
        let outcome = liveBook.apply(event) { author in author ?? self.chief(of: conversation) }
        switch outcome {
        case .ignored: break
        case .changed: live = liveBook.shown
        case .resync: requestLive(conversation)
        }
    }

    /// Asks the owner for its `run.live` snapshot (it arrives as an event).
    func requestLive(_ conversation: ConversationID) {
        let owner = self.source
        // task-owner: one snapshot request; ends with its reply
        Task { await owner.requestLive(of: conversation) }
    }

    /// The conversation's Chief: a frame from an owner that does not stamp
    /// `author` is the Chief's (a Chief conversation has one agent).
    private func chief(of conversation: ConversationID) -> ParticipantID? {
        let agents = summary(conversation)?.participants.filter { $0.kind == .agent } ?? []
        return (agents.first { $0.agentClass == .chief } ?? agents.first)?.id
    }
}
