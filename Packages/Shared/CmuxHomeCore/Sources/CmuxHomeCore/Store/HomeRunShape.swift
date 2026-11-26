import Foundation

/// What a whole-message Home view draws of one conversation's running replies: who writes each
/// one (its typing dots until its message posts), and the Chief run's activity line and thought
/// headline. Never the text: the view shows a reply only when it is posted whole
/// (`HomeReplyDisplay.wholeMessages`), so a talk token leaves this value as it was and wakes no
/// such view (HOT PATH AUDIT area F, handoff/hot-path-audit/stream/AUDIT.md row H1).
public struct HomeRunShape: Hashable, Sendable {
    /// One running reply: the key its posted message will carry, and its author.
    public struct Reply: Hashable, Sendable {
        public var turn: IdempotencyKey
        public var author: ParticipantID

        public init(turn: IdempotencyKey, author: ParticipantID) {
            self.turn = turn
            self.author = author
        }
    }

    /// The running replies in the order their turns began (``HomeStore/streams(in:)`` without text).
    public var replies: [Reply]
    /// The author of the run ``HomeStore/liveRun(in:)`` shows, nil when none.
    public var runner: ParticipantID?
    /// That run's activity line.
    public var activity: HomeLiveActivity?
    /// That run's thought headline.
    public var thought: String?

    public init(replies: [Reply] = [], runner: ParticipantID? = nil, activity: HomeLiveActivity? = nil,
                thought: String? = nil) {
        self.replies = replies
        self.runner = runner
        self.activity = activity
        self.thought = thought
    }

    /// The shape of `run` and `streams`.
    public init(run: HomeLiveRun?, streams: [HomeStreamRow]) {
        self.init(replies: streams.map { Reply(turn: $0.turn, author: $0.author) }, runner: run?.participant,
                  activity: run?.activity, thought: run?.thought)
    }

    /// Nothing runs.
    public var isEmpty: Bool { replies.isEmpty && runner == nil }
}
