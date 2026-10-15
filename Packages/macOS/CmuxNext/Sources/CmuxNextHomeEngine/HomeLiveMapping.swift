public import CmuxHomeCore
public import CmuxNextDaemon
import Foundation

/// A Chief's live frames and run records, local or Cloud, as Home core
/// events. Decoding only: HomeStore (HomeLiveBook) keeps the state. `author`
/// maps an owner's participant id to Home's (the Cloud account becomes the
/// local user; a local id is itself).
nonisolated struct HomeLiveMapping {
    let author: (String) -> ParticipantID

    func event(_ live: ConversationLive) -> HomeLiveEvent? {
        let conversation = ConversationID(live.conversation)
        switch live.frame {
        case .delta(let delta):
            return .delta(HomeLiveDelta(conversation: conversation, author: delta.author.map(author), run: delta.run,
                                        step: delta.step, isTalk: delta.kind == "talk", seq: delta.seq,
                                        text: delta.text, isFinal: delta.final == true))
        case .activity(let frame):
            let line = frame.line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            return .activity(HomeLiveActivityFrame(conversation: conversation, author: frame.author.map(author), run: frame.run,
                                                   activity: HomeLiveActivity(line: line, since: Self.date(frame.since))))
        case .snapshot(let snapshot):
            return .snapshot(conversation: ConversationID(snapshot.conversation), runs: snapshot.runs.map { run in
                HomeLiveRunSnapshot(
                    author: run.author.map(author), run: run.run,
                    steps: (run.steps ?? []).map { .init(step: $0.step, isTalk: $0.kind == "talk", seq: $0.seq, text: $0.text) },
                    activity: run.activity.flatMap { activity in
                        let line = activity.line.trimmingCharacters(in: .whitespacesAndNewlines)
                        return line.isEmpty ? nil : HomeLiveActivity(line: line, since: Self.date(activity.since))
                    })
            })
        case .unknown:
            return nil
        }
    }

    func event(_ changed: ConversationRunChanged) -> HomeLiveEvent {
        .run(HomeLiveRunChange(conversation: ConversationID(changed.conversation), author: author(changed.run.author),
                               run: changed.run.id, turn: changed.run.turn.map { IdempotencyKey($0) }, status: changed.run.status))
    }

    private static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}

nonisolated extension DaemonHomeSource {
    /// `conversation-live` from the local owner.
    public func publish(_ live: ConversationLive) {
        guard let event = HomeLiveMapping(author: { ParticipantID($0) }).event(live) else { return }
        publish(.live(event))
    }

    /// `conversation-run-changed` from the local owner.
    public func publish(_ changed: ConversationRunChanged) {
        publish(.live(HomeLiveMapping(author: { ParticipantID($0) }).event(changed)))
    }

    public func requestLive(of conversation: ConversationID) async {
        guard let connection = try? requireConnection(),
              let answer = try? await ConversationClient(connection).live(conversation.rawValue) else { return }
        publish(ConversationLive(conversation: conversation.rawValue, frame: answer))
    }
}

nonisolated extension CloudHomeSource {
    /// A Cloud Chief's live frame or run record, for a conversation this
    /// account knows, with the account's own id as Home's local user.
    func applyLive(_ build: (HomeLiveMapping) -> HomeLiveEvent?, conversation: String) {
        publish { state in
            guard let identity = state.identity, state.known(ConversationID(conversation)) else { return nil }
            return build(HomeLiveMapping(author: identity.toHome)).map(HomeEvent.live)
        }
    }

    public func requestLive(of conversation: ConversationID) async {
        guard let commands = state.withLock({ $0.commands }) else { return }
        try? await commands.requestLive(conversation.rawValue)
    }
}
