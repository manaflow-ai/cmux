import Foundation

/// An agent's "needs you here" mark on a tab (`extra.attention`, tab-attention-v1): the one
/// line the person reads, and when the agent asked.
public struct TabAttention: Sendable, Hashable {
    public var reason: String
    /// Milliseconds since 1970 on the daemon's clock; each new request has a new value.
    public var atMs: UInt64

    public init(reason: String, atMs: UInt64) {
        self.reason = reason
        self.atMs = atMs
    }

    /// The mark in a tab's `extra.attention` (`{reason, at_ms}`); nil when absent or malformed.
    /// `at_ms` must be a whole nonnegative number: the ring compares requests by it, so a mark
    /// with a missing or bad one would read as the oldest request and stay hidden.
    public init?(_ value: JSONValue?) {
        guard let reason = value?["reason"]?.stringValue, !reason.isEmpty,
              let atMs = value?["at_ms"]?.doubleValue.flatMap({ UInt64(exactly: $0) }) else { return nil }
        self.init(reason: reason, atMs: atMs)
    }
}
