import Foundation

/// One chat's agent processes, as its acpmux daemon measures them (`_acpmux/session_resources`,
/// acpmux `server/requests/session_resources.rs`): the agent host and everything under it, or the
/// agent acpmux runs as its own child. A peer's chat is answered by its own machine. The hover
/// cards' Memory for an agent chat (Leo 2026-11-27: "it should be the ram usage").
public nonisolated struct AcpmuxSessionResources: Sendable, Equatable {
    public struct Process: Sendable, Equatable {
        public var pid: Int32
        public var name: String
        public var cpuNanos: UInt64
        public var memoryBytes: UInt64
    }

    /// nil: unknown (a start or stop held the chat's agent); false: no agent runs (new or hibernated).
    public var running: Bool?
    public var processes: [Process]
    public var sampledAtNanos: UInt64

    public static let method = "_acpmux/session_resources"

    /// The reply's numbers; nil for a reply that is not one.
    public init?(result: [String: Any]) {
        guard let list = result["processes"] as? [[String: Any]] else { return nil }
        running = result["running"] as? Bool
        sampledAtNanos = (result["sampledAtNs"] as? NSNumber)?.uint64Value ?? 0
        processes = list.compactMap { row in
            guard let pid = (row["pid"] as? NSNumber)?.int32Value else { return nil }
            return Process(pid: pid, name: row["name"] as? String ?? "",
                           cpuNanos: (row["cpuNs"] as? NSNumber)?.uint64Value ?? 0,
                           memoryBytes: (row["memoryBytes"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    /// The numbers of `sessionId`'s agent from the acpmux at `socketPath`; nil when the daemon does
    /// not answer within `deadline`, has no such chat, or predates the request (its "method not found").
    @concurrent public static func sample(socketPath: String, sessionId: String,
                                          deadline: Duration = .seconds(1)) async -> AcpmuxSessionResources? {
        guard let result = try? await AcpmuxStatusClient.call(socketPath: socketPath, method: method,
                                                               params: ["sessionId": sessionId], deadline: deadline) else { return nil }
        return AcpmuxSessionResources(result: result)
    }
}
