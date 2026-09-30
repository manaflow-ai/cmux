public import CmuxAgentChat
public import Foundation

/// Attention ordering for agent sessions: one place that decides which session
/// a human should look at first.
///
/// Two other surfaces rank sessions with their own inline comparators: the
/// mobile chat list and the JS custom-sidebar agents panel
/// (`Examples/CustomSidebars/panel-subagents.js`). They agree on the buckets
/// and disagree on the tie-breaks, so a session can sit third in one and first
/// in the other. The ordering here is written to be the one implementation all
/// three use, and `agent.sessions.list` is the first caller; moving the two
/// existing surfaces onto it changes what a user sees, so it belongs in a
/// change that can carry dogfood evidence rather than here.
///
/// The behavior hangs off the types it describes (`ChatAgentState`,
/// `AgentChatSessionRecord` and collections of them) rather than a static
/// namespace, and nothing here touches AppKit, the registry or the clock: the
/// age entry point takes an injected `now`, so the package test target covers
/// the ordering without an app build.

/// The sort bucket a session falls in, loudest first.
///
/// Raw values are the sort keys, so `Rank` ordering *is* bucket ordering.
public enum AgentSessionAttentionRank: Int, Sendable, Comparable, CaseIterable {
    /// The agent asked a question and is parked waiting for an answer.
    case needsInput = 0
    /// The agent is running.
    case working = 1
    /// The agent is alive with nothing in flight.
    case idle = 2
    /// The session is over.
    case ended = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The snake_case name this rank serializes to, matching ``ChatAgentState``'s
    /// own wire vocabulary so clients can compare a session's `state` and
    /// `attention` fields without a mapping table.
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
public struct AgentSessionAttentionCounts: Sendable, Equatable {
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

    public subscript(rank: AgentSessionAttentionRank) -> Int {
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

extension ChatAgentState {
    /// The bucket this state belongs to.
    public var attentionRank: AgentSessionAttentionRank {
        switch self {
        case .needsInput: return .needsInput
        case .working: return .working
        case .idle: return .idle
        case .ended: return .ended
        }
    }

    /// When the current state began, for the two states that carry a start
    /// timestamp.
    ///
    /// `idle` and `ended` have none: the registry records them without a
    /// transition time, and `lastActivityAt` is the only thing known about when
    /// they started.
    public var attentionStateSince: Date? {
        switch self {
        case .working(let since), .needsInput(let since): return since
        case .idle, .ended: return nil
        }
    }

    /// How long this state has been held, or `nil` for a state with no start
    /// timestamp.
    ///
    /// Clamped at zero so a record stamped slightly ahead of the caller's clock
    /// reports "just now" rather than a negative age. Hook timestamps come from
    /// the agent process, not from this process.
    public func attentionStateAgeSeconds(now: Date) -> Double? {
        guard let since = attentionStateSince else { return nil }
        return max(0, now.timeIntervalSince(since))
    }
}

extension AgentChatSessionRecord {
    /// Whether this session should be triaged before `other`.
    ///
    /// Buckets come first (see ``AgentSessionAttentionRank``). Within a bucket
    /// the tie-break flips, because "most interesting" means opposite things for
    /// live and settled work:
    ///
    /// - `needsInput` and `working` sort **oldest first**. The session blocked
    ///   longest is the one costing the most wall clock, and the one running
    ///   longest is the likeliest to be stuck. Both are what you want at the top
    ///   of the list.
    /// - `idle` and `ended` sort **newest activity first**. Nothing is waiting on
    ///   you, so the useful order is recency: what you just touched is what you
    ///   are still thinking about.
    ///
    /// Ties break on `sessionID` ascending. That last step is not cosmetic: it
    /// makes the order total, so tests are not sensitive to the registry's
    /// dictionary iteration order and a UI bound to the list does not reshuffle
    /// equal rows underneath the user.
    func precedesInAttentionOrder(_ other: AgentChatSessionRecord) -> Bool {
        let rank = state.attentionRank
        let otherRank = other.state.attentionRank
        if rank != otherRank { return rank < otherRank }

        switch rank {
        case .needsInput, .working:
            // `attentionStateSince` is non-nil for both of these; the fallback
            // keeps the comparator total if the state ever gains a case without
            // one.
            let since = state.attentionStateSince ?? lastActivityAt
            let otherSince = other.state.attentionStateSince ?? other.lastActivityAt
            if since != otherSince { return since < otherSince }
        case .idle, .ended:
            if lastActivityAt != other.lastActivityAt {
                return lastActivityAt > other.lastActivityAt
            }
        }
        return sessionID < other.sessionID
    }
}

extension Collection<AgentChatSessionRecord> {
    /// These sessions in the order a human should triage them in.
    ///
    /// See ``AgentChatSessionRecord/precedesInAttentionOrder(_:)`` for the rules.
    public func orderedByAttention() -> [AgentChatSessionRecord] {
        sorted { $0.precedesInAttentionOrder($1) }
    }

    /// Per-bucket totals. Order-independent.
    public func attentionCounts() -> AgentSessionAttentionCounts {
        var counts = AgentSessionAttentionCounts()
        for record in self {
            counts[record.state.attentionRank] += 1
        }
        return counts
    }
}
