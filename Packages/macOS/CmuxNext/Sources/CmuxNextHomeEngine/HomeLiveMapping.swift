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
                               run: changed.run.id, turn: changed.run.turn.map { IdempotencyKey($0) }, status: changed.run.status,
                               agentRun: HomeAgentRunMapping.run(changed.summary, conversation: changed.conversation,
                                                               steps: changed.steps ?? [], author: author)))
    }

    private static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    /// A run's talk rows with their text.
    static func talkRows(_ rows: ConversationRunRows) -> [HomeLiveRunSnapshot.Step] {
        rows.steps.compactMap { step in
            // A cut row is not the step's text (the reply brings it): it gives only its place.
            guard step.kind == "talk" else { return nil }
            let text = step.truncated == true ? "" : step.text ?? ""
            return HomeLiveRunSnapshot.Step(step: step.id, isTalk: true, seq: 0, text: text, place: step.seq)
        }
    }
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

    public func liveRunRows(of conversation: ConversationID, run: String, author: ParticipantID) async -> [HomeLiveRunSnapshot.Step]? {
        guard let connection = try? requireConnection(),
              let rows = try? await ConversationClient(connection).runRows(conversation.rawValue, run: run) else { return nil }
        return HomeLiveMapping.talkRows(rows)
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

    public func liveRunRows(of conversation: ConversationID, run: String, author: ParticipantID) async -> [HomeLiveRunSnapshot.Step]? {
        let (commands, identity) = state.withLock { ($0.commands, $0.identity) }
        guard let commands, let identity,
              let rows = try? await commands.runRows(conversation.rawValue, agent: identity.toCloud(author), run: run) else { return nil }
        return HomeLiveMapping.talkRows(rows)
    }
}
