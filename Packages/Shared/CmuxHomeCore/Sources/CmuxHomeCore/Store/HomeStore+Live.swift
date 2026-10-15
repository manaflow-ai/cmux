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
        // A run record names the reply's key (Cloud: Run.turn): a reply that came first ends the run now.
        if case .run = event { settleLive(conversation) }
    }

    /// Ends every live run of `conversation` whose reply is already in the mirror.
    func settleLive(_ conversation: ConversationID) {
        var changed = false
        for (key, turn) in liveBook.turns(in: conversation) {
            if let reply = mirror.message(clientID: turn, in: conversation), reply.author == key.author {
                changed = liveBook.end(key) || changed
            }
        }
        if changed { live = liveBook.shown }
    }

    /// The running Chief run `id` shows (`live`), nil when none.
    public func liveRun(in id: ConversationID) -> HomeLiveRun? { live[id] }

    /// Asks the owner for its `run.live` snapshot (it arrives as an event).
    func requestLive(_ conversation: ConversationID) {
        guard liveRequests.insert(conversation).inserted else { return }
        let owner = self.source
        // task-owner: one snapshot request; ends with its reply
        Task { [weak self] in
            await owner.requestLive(of: conversation)
            self?.liveRequests.remove(conversation)
        }
    }

    /// The conversation's Chief: a frame from an owner that does not stamp
    /// `author` is the Chief's (a Chief conversation has one agent).
    private func chief(of conversation: ConversationID) -> ParticipantID? {
        let agents = summary(conversation)?.participants.filter { $0.kind == .agent } ?? []
        return (agents.first { $0.agentClass == .chief } ?? agents.first)?.id
    }
}
