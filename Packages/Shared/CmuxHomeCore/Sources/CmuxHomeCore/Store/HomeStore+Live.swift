import Foundation

// A Chief's live run frames (`chief-live-v1`) through HomeLiveBook into
// `live`, the one value every Home view draws.
extension HomeStore {
    func applyLive(_ event: HomeLiveEvent) {
        if case .run(let update) = event, let run = update.agentRun { applyAgentRun(run) }
        let conversation = event.conversation
        let outcome = liveBook.apply(event) { author in author ?? self.chief(of: conversation) }
        switch outcome {
        case .ignored: break
        case .changed: publishLive(conversation)
        case .resync: requestLive(conversation)
        }
        // A run record names the reply's key (Cloud: Run.turn): a reply that came first ends the run now.
        if case .run = event { settleLive(conversation) }
        // A snapshot (a join, a reconnect, a gap) lacks the reply segments the owner freed: read the run's rows.
        if case .snapshot = event {
            for (key, _) in liveBook.turns(in: conversation) { readRows(conversation, run: key.run, author: key.author) }
        }
    }

    /// The talk rows of one running run, once per run at a time (cx-kdm25).
    private func readRows(_ conversation: ConversationID, run: String, author: ParticipantID) {
        let id = "\(conversation.rawValue)\u{0}\(author.rawValue)\u{0}\(run)"
        guard liveRowReads.insert(id).inserted else { return }
        let owner = self.source
        // task-owner: one run read; ends with its reply
        Task { [weak self] in
            let rows = await owner.liveRunRows(of: conversation, run: run, author: author)
            guard let self else { return }
            self.liveRowReads.remove(id)
            if let rows { self.applyLive(.rows(conversation: conversation, author: author, run: run, steps: rows)) }
        }
    }

    /// Ends every live run of `conversation` whose reply is already in the mirror.
    func settleLive(_ conversation: ConversationID) {
        var changed = false
        for (key, turn) in liveBook.turns(in: conversation) {
            if let reply = mirror.message(clientID: turn, in: conversation), reply.author == key.author {
                changed = liveBook.end(key) || changed
            }
        }
        if changed { publishLive(conversation) }
    }

    /// After the live or draft book changed for `conversation`: `live`, `drafts` and that
    /// conversation's `streams` take the books' values (each assigned only when it changed, so an
    /// unchanged one wakes no observer).
    func publishLive(_ conversation: ConversationID) {
        let shown = liveBook.shown
        if live != shown { live = shown }
        if drafts != draftBook.live { drafts = draftBook.live }
        let rows = streamRows(conversation)
        if streams[conversation, default: []] != rows { streams[conversation] = rows.isEmpty ? nil : rows }
    }

    /// Every running reply of `conversation` in begin order: the Chief live runs, then a reply
    /// from an older owner's `conversation-draft` that is not one of them.
    private func streamRows(_ conversation: ConversationID) -> [HomeStreamRow] {
        var rows = liveBook.streams(in: conversation).map { HomeStreamRow(turn: $0.turn, author: $0.participant, text: $0.text) }
        if let draft = draftBook.live[conversation], !rows.contains(where: { $0.turn == draft.turn }) {
            rows.append(HomeStreamRow(turn: draft.turn, author: draft.participant, text: draft.text))
        }
        return rows.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The running replies of `id`, in the order their turns began (``HomeTimeline/streams``).
    public func streams(in id: ConversationID) -> [HomeStreamRow] { streams[id] ?? [] }

    /// The running Chief run `id` shows (`live`), nil when none.
    public func liveRun(in id: ConversationID) -> HomeLiveRun? { live[id] }

    /// Who shows typing dots in `id`: the owner's typing frames, plus the author of a run still
    /// running there. One rule for every view: typing frames do not outlive a connection
    /// (`handle(.connection)`), a running turn's dots come from its live run.
    public func typists(in id: ConversationID) -> Set<ParticipantID> {
        (typing[id] ?? []).union(live[id].map { [$0.participant] } ?? [])
    }

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
