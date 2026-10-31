import Foundation

/// An agent's "needs you here" mark on a tab (`extra.attention`, tab-attention-v1): the one
/// line the person reads, and when the agent asked.
public struct TabAttention: Sendable, Hashable {
    public var reason: String
    /// Milliseconds since 1970 on the daemon's clock, for display and ordering only.
    public var atMs: UInt64
    /// Owner-issued identity. New daemons persist a 32-character lowercase hex token.
    public var requestID: String?

    public init(reason: String, atMs: UInt64, requestID: String? = nil) {
        self.reason = reason
        self.atMs = atMs
        self.requestID = requestID.flatMap { Self.validRequestID($0) ? $0 : nil }
    }

    /// The mark in a tab's `extra.attention` (`{reason, at_ms, request_id}`); nil when absent or malformed.
    public init?(_ value: JSONValue?) {
        guard let reason = value?["reason"]?.stringValue, !reason.isEmpty,
              let atMs = value?["at_ms"]?.doubleValue.flatMap({ UInt64(exactly: $0) }) else { return nil }
        let requestID = value?["request_id"]?.stringValue
        if value?["request_id"] != nil {
            guard let requestID, Self.validRequestID(requestID) else { return nil }
        }
        self.init(reason: reason, atMs: atMs, requestID: requestID)
    }

    public static func validRequestID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
