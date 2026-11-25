import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxContentTests {
    private actor Client: AgentSessionRemoteClient {
        nonisolated let isReadOnly = false
        var contents: Data?
        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            Data(#"{"session":{"sessionId":"s"},"events":[],"hasMore":false,"lastSeq":0}"#.utf8)
        }
        func events(_ page: AgentSessionPage) async throws -> Data { Data("{}".utf8) }
        func prompt(id: String, text: String) async throws -> Data { throw CocoaError(.featureUnsupported) }
        func prompt(id: String, content: Data) async throws -> Data {
            contents = content
            return Data(#"{"turn_id":"turn-one","queued":false}"#.utf8)
        }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?, personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
        func media(path: String) async throws -> Data { throw CocoaError(.featureUnsupported) }
    }

    @MainActor @Test func aCloudImageAndRemoteFileReferenceReachTheOwningSessionUnchanged() async throws {
        let client = Client()
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let wire = RemoteAcpmuxWire(client: client, session: "s")
        try await wire.open(onFrame: { inbox.deliver([$0]) }, onClose: { _, _ in })
        defer { wire.cancel(code: 1000, reason: "done") }
        wire.send(#"{"id":1,"method":"_acpmux/attach","params":{"sessionId":"s"}}"#) { _ in }
        _ = await inbox.frame(containing: "\"lastSeq\"")
        wire.send(#"{"id":2,"method":"session/prompt","params":{"sessionId":"s","prompt":[{"type":"text","text":"Explain this"},{"type":"image","mimeType":"image/png","data":"YWJj","name":"screen.png"},{"type":"resource_link","uri":"file:///home/cmux/work/local/uploads/one/screen.png","name":"screen.png"}]}}"#) { _ in }
        _ = await inbox.frame(containing: "turn-one")
        let content = try #require(await client.contents)
        let blocks = try #require(JSONSerialization.jsonObject(with: content) as? [[String: String]])
        #expect(blocks.map { $0["type"] } == ["text", "image", "resource_link"])
        #expect(blocks[1]["data"] == "YWJj")
        #expect(blocks[2]["uri"] == "file:///home/cmux/work/local/uploads/one/screen.png")
    }

    @MainActor @Test func aPastedTextOnlyPromptKeepsItsMetadataThroughTheWire() async throws {
        let client = Client()
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let wire = RemoteAcpmuxWire(client: client, session: "s")
        try await wire.open(onFrame: { inbox.deliver([$0]) }, onClose: { _, _ in })
        defer { wire.cancel(code: 1000, reason: "done") }
        wire.send(#"{"id":1,"method":"_acpmux/attach","params":{"sessionId":"s"}}"#) { _ in }
        _ = await inbox.frame(containing: "\"lastSeq\"")
        wire.send(#"{"id":2,"method":"session/prompt","params":{"sessionId":"s","prompt":[{"type":"text","text":"notes","_meta":{"cmux":{"pasted":true}}}]}}"#) { _ in }
        _ = await inbox.frame(containing: "turn-one")
        let content = try #require(await client.contents)
        let blocks = try #require(JSONSerialization.jsonObject(with: content) as? [[String: Any]])
        let meta = try #require(blocks[0]["_meta"] as? [String: [String: Bool]])
        #expect(meta == ["cmux": ["pasted": true]])
        #expect(RemoteAcpmuxWire.text([["type": "text", "text": "legacy"]]) == "legacy")
    }
}
