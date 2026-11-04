import Foundation
import Testing
@testable import CmuxNextDaemon

@Suite(.timeLimit(.minutes(1))) struct AgentSessionAttachClientContextTests {
    @Test func contextUsesOnlyTheAttachedSurfaceAndPreservesEmptyAndResetOverrides() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-context-v1"])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        _ = try await client.context()
        _ = try await client.setContextOverride(scope: "user", text: "Read early.\nRead concurrently.")
        _ = try await client.setContextOverride(scope: "project", text: "")
        _ = try await client.setContextOverride(scope: "project", text: nil)
        await client.close()
        let sent = daemon.frames.filter { $0["cmd"] as? String == "agent-session-context" }
        #expect(sent.count == 4)
        #expect(sent.allSatisfy { $0["surface"] as? Int == 7 && $0["sessionId"] == nil && $0["cwd"] == nil })
        #expect(sent[0]["op"] as? String == "get")
        #expect(sent[1]["op"] as? String == "set" && sent[1]["scope"] as? String == "user")
        #expect(sent[1]["text"] as? String == "Read early.\nRead concurrently.")
        #expect(sent[2]["text"] as? String == "")
        #expect(sent[3]["text"] == nil)
    }

    @Test func olderDaemonsGetAnUpdateErrorAndNoContextVerb() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1"])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        await #expect(throws: AgentSessionAttachError.self) { _ = try await client.context() }
        await #expect(throws: AgentSessionAttachError.self) { _ = try await client.setContextOverride(scope: "user", text: "edit") }
        await client.close()
        #expect(!daemon.frames.contains { $0["cmd"] as? String == "agent-session-context" })
    }
}
