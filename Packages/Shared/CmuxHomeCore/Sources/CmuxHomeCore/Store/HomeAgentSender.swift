/// Who wrote a message in an agent's chat with the Chief (the agent pane's label over it).
///
/// User 2026-11-03 (msg 19960): the person and the Chief share the pane's composer, so every message to
/// the agent says who sent it. An outgoing prompt can carry `_meta.cmux.sender` (`human:<participant>` or
/// `chief:<id>`); ``init(meta:)`` reads it.
public enum HomeAgentSender: Hashable, Sendable {
    /// The agent itself: its report or a status note (no label).
    case agent
    /// The Chief, through its `tell` tool or its spawn.
    case chief
    /// The person, through the pane's composer.
    case you

    /// The sender a `_meta.cmux.sender` value names: `human:<participant>` is ``you``, `chief:<id>` is
    /// ``chief``.
    ///
    /// - Parameter meta: The value of `_meta.cmux.sender`.
    /// - Returns: Nil for an empty or unknown value (the caller falls back to its own rule).
    public init?(meta: String) {
        guard let colon = meta.firstIndex(of: ":"), meta.index(after: colon) < meta.endIndex else { return nil }
        switch meta[..<colon] {
        case "human": self = .you
        case "chief": self = .chief
        default: return nil
        }
    }
}
