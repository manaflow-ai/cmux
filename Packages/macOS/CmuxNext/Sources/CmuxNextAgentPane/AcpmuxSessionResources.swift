import CmuxNextDaemon
public import CmuxNextResources
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

    /// An agent chat to measure: its tab, its acpmux session, and the `AgentSessionRef.host` it runs on.
    public struct Query: Sendable, Equatable {
        public var tabID: String
        public var session: String
        public var host: String

        public init(tabID: String, session: String, host: String) {
            self.tabID = tabID
            self.session = session
            self.host = host
        }
    }

    /// Every chat's agent processes, keyed by tab, asked all at once, each within its deadline. A chat on
    /// this install (`localInstallID`) is this Mac's processes; a peer's chat keys them by its host, so
    /// the hover cards never fold them into a local pid. Leo 2026-11-27: "the memory line... it should
    /// be the ram usage. why dont we have ram usage?" The chat page alone was often unmatched
    /// ("Memory –") and never held the agent, which runs in acpmux.
    @concurrent public static func samples(of queries: [Query], socketPath: String?,
                                           localInstallID: String?) async -> [String: [ProcessSample]] {
        guard let socketPath, !queries.isEmpty else { return [:] }
        let localHost = localInstallID.map(AgentSessionRef.host(installID:))
        return await withTaskGroup(of: (Query, AcpmuxSessionResources?).self) { group in
            for query in queries {
                group.addTask { (query, await sample(socketPath: socketPath, sessionId: query.session)) }
            }
            var byTab: [String: [ProcessSample]] = [:]
            for await (query, reply) in group {
                guard let reply, !reply.processes.isEmpty else { continue }
                let host = query.host == localHost ? ProcessKey.localHost : query.host
                byTab[query.tabID, default: []] += reply.processes.map { process in
                    ProcessSample(key: ProcessKey(host: host, pid: process.pid), name: process.name,
                                  cpuNanos: process.cpuNanos, memoryBytes: process.memoryBytes,
                                  sampledAtNanos: reply.sampledAtNanos)
                }
            }
            return byTab
        }
    }
}
