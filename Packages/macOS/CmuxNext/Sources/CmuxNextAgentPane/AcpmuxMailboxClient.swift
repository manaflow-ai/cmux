public import Foundation

/// One row returned by the daemon-local ACPMUX mailbox.
public nonisolated struct AcpmuxMailboxMessage: Sendable, Equatable {
    public let id: String
    public let seq: UInt64
    public let sender: String
    public let body: String
    public let createdAt: Date

    init(id: String, seq: UInt64, sender: String, body: String, createdAt: Date) {
        self.id = id
        self.seq = seq
        self.sender = sender
        self.body = body
        self.createdAt = createdAt
    }
}

/// A bounded mailbox page. The cursor is advanced by the caller after it
/// projects the rows, so a process restart re-reads only the last page.
public nonisolated struct AcpmuxMailboxPage: Sendable, Equatable {
    public let messages: [AcpmuxMailboxMessage]
    public let nextCursor: UInt64?

    init(messages: [AcpmuxMailboxMessage], nextCursor: UInt64?) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

/// Reads the app-owned reports alias over the daemon's authenticated Unix
/// socket. The daemon keeps the alias separate from attached ACP sessions, so
/// this path never marks an agent seen or injects a model turn.
public nonisolated struct AcpmuxMailboxClient: Sendable {
    public init() {}

    @concurrent
    public func wait(socketPath: String, recipient: String, after: UInt64, limit: UInt64 = 100,
                     timeoutMs: UInt64 = 30_000) async throws -> AcpmuxMailboxPage {
        let boundedTimeoutMs = min(timeoutMs, 30_000)
        let result = try await AcpmuxStatusClient.call(
            socketPath: socketPath,
            method: "_acpmux/mail/wait",
            params: [
                "recipient": recipient,
                "after": after,
                "limit": min(limit, 500),
                "timeoutMs": boundedTimeoutMs,
            ],
            deadline: .milliseconds(Int64(boundedTimeoutMs) + 2_000)
        )
        let rows = (result["messages"] as? [[String: Any]] ?? []).compactMap(Self.message)
        let nextCursor = (result["nextCursor"] as? NSNumber).flatMap { UInt64(exactly: $0.uint64Value) }
        return AcpmuxMailboxPage(messages: rows, nextCursor: nextCursor)
    }

    private static func message(_ row: [String: Any]) -> AcpmuxMailboxMessage? {
        guard let message = row["message"] as? [String: Any],
              let id = message["id"] as? String,
              let sender = message["sender"] as? String,
              let body = message["body"] as? String,
              let seqNumber = message["seq"] as? NSNumber,
              let seq = UInt64(exactly: seqNumber.uint64Value),
              let createdNumber = message["createdAt"] as? NSNumber else { return nil }
        return AcpmuxMailboxMessage(
            id: id,
            seq: seq,
            sender: sender,
            body: body,
            createdAt: Date(timeIntervalSince1970: createdNumber.doubleValue / 1_000)
        )
    }
}
