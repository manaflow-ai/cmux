public import Foundation

/// A Chief's live run frames (`chief-live-v1`, the "Live frames" contract the
/// local optchat-chief and the Cloud Chief brain share), as the sources hand
/// them to HomeStore. Ephemeral: never a message and never stored.
public enum HomeLiveEvent: Hashable, Sendable {
    /// `step.delta`: text appended to a step of a running run.
    case delta(HomeLiveDelta)
    /// `run.activity`: what the run works on now (the newest wins).
    case activity(HomeLiveActivityFrame)
    /// `run.live`: the owner's text so far and activity of every running run
    /// of the conversation; it replaces what the client kept.
    case snapshot(conversation: ConversationID, runs: [HomeLiveRunSnapshot])
    /// A run record changed (`conversation-run-changed`): its reply key and status.
    case run(HomeLiveRunChange)
    /// A running run's talk rows, read after a snapshot: the segments the owner already freed.
    case rows(conversation: ConversationID, author: ParticipantID, run: String, steps: [HomeLiveRunSnapshot.Step])

    var conversation: ConversationID {
        switch self {
        case .delta(let delta): delta.conversation
        case .activity(let activity): activity.conversation
        case .snapshot(let conversation, _): conversation
        case .run(let change): change.conversation
        case .rows(let conversation, _, _, _): conversation
        }
    }
}

public struct HomeLiveDelta: Hashable, Sendable {
    public var conversation: ConversationID
    /// The Chief; nil from an owner that does not stamp it (the conversation's Chief).
    public var author: ParticipantID?
    public var run: String
    public var step: String
    public var isTalk: Bool
    public var seq: UInt64
    public var text: String
    public var isFinal: Bool

    public init(conversation: ConversationID, author: ParticipantID?, run: String, step: String, isTalk: Bool,
                seq: UInt64, text: String, isFinal: Bool) {
        self.conversation = conversation
        self.author = author
        self.run = run
        self.step = step
        self.isTalk = isTalk
        self.seq = seq
        self.text = text
        self.isFinal = isFinal
    }
}

/// The "working on" line ("Editing src/app.ts in sb-3") and when that work began.
public struct HomeLiveActivity: Hashable, Sendable {
    public var line: String
    public var since: Date

    public init(line: String, since: Date) {
        self.line = line
        self.since = since
    }
}

public struct HomeLiveActivityFrame: Hashable, Sendable {
    public var conversation: ConversationID
    public var author: ParticipantID?
    public var run: String
    public var activity: HomeLiveActivity

    public init(conversation: ConversationID, author: ParticipantID?, run: String, activity: HomeLiveActivity) {
        self.conversation = conversation
        self.author = author
        self.run = run
        self.activity = activity
    }
}

public struct HomeLiveRunSnapshot: Hashable, Sendable {
    public struct Step: Hashable, Sendable {
        public var step: String
        public var isTalk: Bool
        /// The last frame the text includes.
        public var seq: UInt64
        public var text: String
        /// A row's place in the run (the owner's `Step.seq`); nil for a live step.
        public var place: UInt64?

        public init(step: String, isTalk: Bool, seq: UInt64, text: String, place: UInt64? = nil) {
            self.step = step
            self.isTalk = isTalk
            self.seq = seq
            self.text = text
            self.place = place
        }
    }

    public var author: ParticipantID?
    public var run: String
    public var steps: [Step]
    public var activity: HomeLiveActivity?

    public init(author: ParticipantID?, run: String, steps: [Step], activity: HomeLiveActivity?) {
        self.author = author
        self.run = run
        self.steps = steps
        self.activity = activity
    }
}

public struct HomeLiveRunChange: Hashable, Sendable {
    public var conversation: ConversationID
    public var author: ParticipantID
    public var run: String
    /// The reply's `client_msg_id` (Run.turn); nil: the run id (the local Chief's turn key).
    public var turn: IdempotencyKey?
    /// `running`, `done`, `failed` or `cancelled` (TRAJECTORIES.md Run.status).
    public var status: String
    /// Persisted agent-message steps accompanying this run update.
    public var agentRun: HomeAgentRun?

    public init(conversation: ConversationID, author: ParticipantID, run: String, turn: IdempotencyKey?, status: String, agentRun: HomeAgentRun? = nil) {
        self.conversation = conversation
        self.author = author
        self.run = run
        self.turn = turn
        self.status = status
        self.agentRun = agentRun
    }
}

/// What one conversation shows of its running Chief run: the reply so far in
/// the Chief's bubble, and the activity line under the transcript.
public struct HomeLiveRun: Hashable, Sendable {
    public var participant: ParticipantID
    public var run: String
    /// The posted reply's key: it takes the bubble's place.
    public var turn: IdempotencyKey
    /// The run's talk steps in order, joined by a blank line ("" before the first text).
    public var text: String
    public var activity: HomeLiveActivity?
    /// The headline of the run's newest thought (`String.thoughtHeadline`), kept after its step ends
    /// until the next thought; nil when there is none.
    /// Home's running indicator shows its headline as the Chief's progress narration.
    public var thought: String? = nil

    /// The reply so far as HomeStore's running reply, so the view grows it as
    /// it grows a `conversation-draft` and lands the posted reply in it.
    public var turnDraft: HomeTurnDraft {
        var draft = HomeTurnDraft(participant: participant, turn: turn)
        draft.segments[0] = text
        return draft
    }
}
