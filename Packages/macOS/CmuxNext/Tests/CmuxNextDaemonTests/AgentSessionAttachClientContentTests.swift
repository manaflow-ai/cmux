import Foundation
import Testing
@testable import CmuxNextDaemon

@Suite(.timeLimit(.minutes(1))) struct AgentSessionAttachClientContentTests {
    private let pasted = Data(#"[{"type":"text","text":"Before"},{"type":"text","text":"notes","_meta":{"cmux":{"pasted":true}}},{"type":"text","text":"After"}]"#.utf8)

    @Test func anOlderDaemonKeepsPastedTextWorkingWithoutANewContentField() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1"])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        _ = try await client.attach(afterSeq: nil, beforeSeq: nil, limit: nil, kinds: nil) { _, _ in }
        _ = try await client.prompt(id: "paste", content: pasted)
        await client.close()
        let frame = try #require(daemon.frames.last)
        #expect(frame["cmd"] as? String == "agent-session-prompt")
        #expect(frame["surface"] as? Int == 7)
        #expect(frame["prompt_id"] as? String == "paste")
        #expect(frame["text"] as? String == "Before\n\nnotes\n\nAfter")
        #expect(frame["content"] == nil)
    }

    @Test func aCapableDaemonRetainsTheOrderedContentAndPastedMarker() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-content-v1"])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        _ = try await client.attach(afterSeq: nil, beforeSeq: nil, limit: nil, kinds: nil) { _, _ in }
        _ = try await client.prompt(id: "paste", content: pasted)
        await client.close()
        let frame = try #require(daemon.frames.last)
        #expect(frame["cmd"] as? String == "agent-session-prompt")
        #expect(frame["text"] == nil)
        let actual = try #require(frame["content"] as? NSArray)
        let expected = try #require(JSONSerialization.jsonObject(with: pasted) as? NSArray)
        #expect(actual == expected)
    }

    @Test func anOlderDaemonRefusesMediaBeforeSendingInsteadOfDroppingIt() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1"])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        _ = try await client.attach(afterSeq: nil, beforeSeq: nil, limit: nil, kinds: nil) { _, _ in }
        for block in [
            #"{"type":"image","mimeType":"image/png","data":"YWJj"}"#,
            #"{"type":"document","mimeType":"application/pdf","data":"YWJj"}"#,
            #"{"type":"audio","mimeType":"audio/wav","data":"YWJj"}"#,
            #"{"type":"resource_link","uri":"file:///work/image.png","name":"image.png"}"#,
        ] {
            await #expect(throws: AgentSessionAttachError(code: "agent_session.content_unsupported",
                                                        message: "Update cmux on that machine to send attachments.")) {
                _ = try await client.prompt(id: "media", content: Data("[\(block)]".utf8))
            }
        }
        await client.close()
        #expect(!daemon.frames.contains { $0["cmd"] as? String == "agent-session-prompt" })
    }
}
