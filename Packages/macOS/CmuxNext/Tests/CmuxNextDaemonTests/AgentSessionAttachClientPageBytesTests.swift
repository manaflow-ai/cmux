import Foundation
import Testing
@testable import CmuxNextDaemon

/// hq#14027: a Cloud chat's pages carry the pane's byte budget to that machine's daemon, which
/// passes it to acpmux; without it each open, read-ahead and reconnect read acpmux's 1 MiB default.
@Suite(.timeLimit(.minutes(1))) struct AgentSessionAttachClientPageBytesTests {
    @Test func aCapableDaemonGetsThePagesByteBudget() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-page-bytes-v1"])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        _ = try await client.attach(afterSeq: nil, beforeSeq: nil, limit: 400, kinds: nil, maxBytes: 131_072) { _, _ in }
        _ = try await client.events(afterSeq: nil, beforeSeq: 9, limit: 400, kinds: nil, maxBytes: 131_072)
        await client.close()
        let pages = daemon.frames.filter { ["agent-session-attach", "agent-session-events"].contains($0["cmd"] as? String) }
        #expect(pages.count == 2)
        #expect(pages.allSatisfy { $0["max_bytes"] as? Int == 131_072 })
    }

    @Test func anOlderDaemonNeverSeesTheField() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1"])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        _ = try await client.attach(afterSeq: nil, beforeSeq: nil, limit: 400, kinds: nil, maxBytes: 131_072) { _, _ in }
        _ = try await client.events(afterSeq: nil, beforeSeq: 9, limit: 400, kinds: nil, maxBytes: 131_072)
        await client.close()
        let pages = daemon.frames.filter { ["agent-session-attach", "agent-session-events"].contains($0["cmd"] as? String) }
        #expect(pages.count == 2)
        #expect(pages.allSatisfy { $0["max_bytes"] == nil })
    }
}
