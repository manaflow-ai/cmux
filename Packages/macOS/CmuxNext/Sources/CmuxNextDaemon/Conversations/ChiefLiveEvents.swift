import Foundation

/// One live frame of a Chief's running run (`chief-live-v1`, the "Live frames"
/// contract the local optchat-chief and the Cloud Chief brain share). The
/// owner sends each one unchanged inside a `conversation-live` (local) or
/// `cloud-conversation-live` (Cloud, through the daemon) event. A frame of a
/// type this build does not know is `.unknown` and changes nothing.
public enum ChiefLiveFrame: Decodable, Sendable, Hashable {
    /// `step.delta`: text appended to a talk or thought step.
    case delta(StepDelta)
    /// `run.activity`: what the run works on now (the newest wins).
    case activity(RunActivity)
    /// `run.live`: the text so far and the activity of every running run.
    case snapshot(RunLive)
    case unknown

    public struct StepDelta: Decodable, Sendable, Hashable {
        public var conversation: String
        public var run: String
        public var step: String
        public var kind: String
        public var seq: UInt64
        public var text: String
        public var final: Bool?
        /// The Chief participant; the owner stamps it (run ids repeat across Chiefs).
        public var author: String?
    }

    public struct RunActivity: Decodable, Sendable, Hashable {
        public var conversation: String
        public var run: String
        public var line: String
        /// When the activity began (ms since 1970); the app draws the elapsed time itself.
        public var since: Double
        public var at: Double?
        public var author: String?
    }

    public struct RunLive: Decodable, Sendable, Hashable {
        public struct Step: Decodable, Sendable, Hashable {
            public var step: String
            public var kind: String
            public var seq: UInt64
            public var text: String
        }

        public struct Activity: Decodable, Sendable, Hashable {
            public var line: String
            public var since: Double
            public var at: Double?
        }

        public struct Run: Decodable, Sendable, Hashable {
            public var run: String
            public var author: String?
            public var steps: [Step]?
            public var activity: Activity?
        }

        public var conversation: String
        public var runs: [Run]
    }

    private enum Keys: String, CodingKey { case type, t }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        let type = try keys.decodeIfPresent(String.self, forKey: .type) ?? keys.decodeIfPresent(String.self, forKey: .t)
        let value = try decoder.singleValueContainer()
        switch type {
        case "step.delta": self = .delta(try value.decode(StepDelta.self))
        case "run.activity": self = .activity(try value.decode(RunActivity.self))
        case "run.live": self = .snapshot(try value.decode(RunLive.self))
        default: self = .unknown
        }
    }
}

/// `conversation-live` (local owner) and `cloud-conversation-live` (a Cloud
/// Chief through the daemon): one live frame of a conversation, never stored.
public struct ConversationLive: Decodable, Sendable, Hashable {
    public var conversation: String
    public var frame: ChiefLiveFrame
    /// The Cloud account the event came through (Cloud only).
    public var account: String?

    public init(conversation: String, frame: ChiefLiveFrame, account: String? = nil) {
        self.conversation = conversation
        self.frame = frame
        self.account = account
    }
}

/// `conversation-run-changed` (local) and `cloud-conversation-run-changed`
/// (Cloud): a run after an append, including persisted agent messages and their placement.
public struct ConversationRunChanged: Decodable, Sendable, Hashable {
    public struct Run: Decodable, Sendable, Hashable {
        public var id: String
        public var author: String
        public var turn: String?
        public var status: String
        public var answers: [String]?
        public var threadRoot: String?
        public var startedAt: Double?
        public var rev: UInt64?
        public var lastStepSeq: UInt64?

        private enum CodingKeys: String, CodingKey {
            case id, author, turn, status, answers, rev
            case threadRoot = "thread_root"
            case startedAt = "started_at"
            case lastStepSeq = "last_step_seq"
        }

        public init(id: String, author: String, turn: String?, status: String, answers: [String]? = nil,
                    threadRoot: String? = nil, startedAt: Double? = nil, rev: UInt64? = nil, lastStepSeq: UInt64? = nil) {
            self.id = id; self.author = author; self.turn = turn; self.status = status
            self.answers = answers; self.threadRoot = threadRoot; self.startedAt = startedAt
            self.rev = rev; self.lastStepSeq = lastStepSeq
        }
    }

    public var conversation: String
    public var run: Run
    public var steps: [ConversationRunRows.Step]?
    public var account: String?

    public var summary: ConversationRunSummary {
        ConversationRunSummary(id: run.id, author: run.author, turn: run.turn, status: run.status,
                               answers: run.answers, threadRoot: run.threadRoot, startedAt: run.startedAt,
                               rev: run.rev, lastStepSeq: run.lastStepSeq)
    }
}
