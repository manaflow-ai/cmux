public import CmuxAgentChat
public import Foundation

/// Attention ordering for agent sessions: the one place that decides which
/// session a human should look at first.
///
/// Three surfaces already rank sessions, each with its own inline comparator:
/// the mobile chat list, the JS custom-sidebar agents panel
/// (`Examples/CustomSidebars/panel-subagents.js`), and now the
/// `agent.sessions.list` socket verb. They agreed on the buckets and disagreed
/// on the tie-breaks, so a session could sit third in one surface and first in
/// another. This type owns the decision so the surfaces can only differ in
/// presentation.
///
/// It is deliberately free of AppKit, the registry, and the clock: every
/// entry point takes the records and (where age matters) an injected `now`, so
/// the package test target covers the ordering without an app build.
public enum AgentSessionAttention {
    /// The sort bucket a session falls in, loudest first.
    ///
    /// Raw values are the sort keys, so `Rank` ordering *is* bucket ordering.
    public enum Rank: Int, Sendable, Comparable, CaseIterable {
        /// The agent asked a question and is parked waiting for an answer.
        case needsInput = 0
        /// The agent is running.
        case working = 1
        /// The agent is alive with nothing in flight.
        case idle = 2
        /// The session is over.
        case ended = 3

        public static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The snake_case name this rank serializes to, matching
        /// ``ChatAgentState``'s own wire vocabulary so clients can compare a
        /// session's `state` and `attention` fields without a mapping table.
        public var wireName: String {
            switch self {
            case .needsInput: return "needs_input"
            case .working: return "working"
            case .idle: return "idle"
            case .ended: return "ended"
            }
        }
    }

    /// Per-bucket totals, for a header or footer summary.
    public struct Counts: Sendable, Equatable {
        public var needsInput: Int
        public var working: Int
        public var idle: Int
        public var ended: Int

        public init(needsInput: Int = 0, working: Int = 0, idle: Int = 0, ended: Int = 0) {
            self.needsInput = needsInput
            self.working = working
            self.idle = idle
            self.ended = ended
        }

        public var total: Int { needsInput + working + idle + ended }

        public subscript(rank: Rank) -> Int {
            get {
                switch rank {
                case .needsInput: return needsInput
                case .working: return working
                case .idle: return idle
                case .ended: return ended
                }
            }
            set {
                switch rank {
                case .needsInput: needsInput = newValue
                case .working: working = newValue
                case .idle: idle = newValue
                case .ended: ended = newValue
                }
            }
        }
    }

    /// The bucket a state belongs to.
    public static func rank(_ state: ChatAgentState) -> Rank {
        switch state {
        case .needsInput: return .needsInput
        case .working: return .working
        case .idle: return .idle
        case .ended: return .ended
        }
    }

    /// When the current state began, for the two states that carry a start
    /// timestamp. `idle` and `ended` have none: the registry records them
    /// without a transition time, and `lastActivityAt` is the only thing known
    /// about when they started.
    public static func stateSince(_ state: ChatAgentState) -> Date? {
        switch state {
        case .working(let since), .needsInput(let since): return since
        case .idle, .ended: return nil
        }
    }

    /// How long the session has held its current state, or `nil` for a state
    /// with no start timestamp.
    ///
    /// Clamped at zero so a record stamped slightly ahead of the caller's clock
    /// reports "just now" rather than a negative age. Hook timestamps come from
    /// the agent process, not from this process.
    public static func stateAgeSeconds(_ state: ChatAgentState, now: Date) -> Double? {
        guard let since = stateSince(state) else { return nil }
        return max(0, now.timeIntervalSince(since))
    }

    /// Sorts sessions into the order a human should triage them in.
    ///
    /// Buckets come first (see ``Rank``). Within a bucket the tie-break flips,
    /// because "most interesting" means opposite things for live and settled
    /// work:
    ///
    /// - `needsInput` and `working` sort **oldest first**. The session blocked
    ///   longest is the one costing the most wall clock, and the one running
    ///   longest is the likeliest to be stuck. Both are what you want at the
    ///   top of the list.
    /// - `idle` and `ended` sort **newest activity first**. Nothing is waiting
    ///   on you, so the useful order is recency: what you just touched is what
    ///   you are still thinking about.
    ///
    /// Ties break on `sessionID` ascending. That last step is not cosmetic: it
    /// makes the output a total order, so tests are not sensitive to the
    /// registry's dictionary iteration order and a UI bound to this list does
    /// not reshuffle equal rows underneath the user.
    public static func ordered(_ records: [AgentChatSessionRecord]) -> [AgentChatSessionRecord] {
        records.sorted(by: precedes)
    }

    /// The comparator behind ``ordered(_:)``, exposed for tests.
    static func precedes(_ lhs: AgentChatSessionRecord, _ rhs: AgentChatSessionRecord) -> Bool {
        let lhsRank = rank(lhs.state)
        let rhsRank = rank(rhs.state)
        if lhsRank != rhsRank { return lhsRank < rhsRank }

        switch lhsRank {
        case .needsInput, .working:
            // `stateSince` is non-nil for both of these; the fallback keeps the
            // comparator total if the state ever gains a case without one.
            let lhsSince = stateSince(lhs.state) ?? lhs.lastActivityAt
            let rhsSince = stateSince(rhs.state) ?? rhs.lastActivityAt
            if lhsSince != rhsSince { return lhsSince < rhsSince }
        case .idle, .ended:
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
        }
        return lhs.sessionID < rhs.sessionID
    }

    /// Per-bucket totals for a set of records. Order-independent.
    public static func counts(_ records: [AgentChatSessionRecord]) -> Counts {
        var counts = Counts()
        for record in records {
            counts[rank(record.state)] += 1
        }
        return counts
    }

    /// Sessions that are actively blocked on a human.
    ///
    /// Only `needsInput` qualifies, matching ``ChatAgentState/needsAttention``.
    /// A long-running `working` session sorts high but is not waiting on
    /// anyone, so it must not light up a "needs me" filter.
    public static func needingAttention(
        _ records: [AgentChatSessionRecord]
    ) -> [AgentChatSessionRecord] {
        ordered(records.filter { $0.state.needsAttention })
    }
}
