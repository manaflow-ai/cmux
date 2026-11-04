import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RemoteAcpmuxWireContextTests {
    private actor Client: AgentSessionRemoteClient {
        nonisolated let isReadOnly: Bool
        var edits: [(String, String?)] = []
        var reads = 0

        init(readOnly: Bool = false) { isReadOnly = readOnly }
        func context() async throws -> Data {
            reads += 1
            return Data(#"{"parts":[{"source":"cmux","text":"Read early.","tokens":3}]}"#.utf8)
        }
        func setContextOverride(scope: String, text: String?) async throws -> Data {
            edits.append((scope, text))
            return Data(#"{"saved":true}"#.utf8)
        }
        func attach(_ page: AgentSessionPage, events: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data { Data("{}".utf8) }
        func events(_ page: AgentSessionPage) async throws -> Data { Data("{}".utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data("{}".utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?, personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
    }

    @Test func contextForwardsOnlyTheCurrentSessionAndPreservesOverrideText() async throws {
        let client = Client()
        let wire = RemoteAcpmuxWire(client: client, session: "s")
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        try await wire.open(onFrame: { inbox.deliver([$0]) }, onClose: { _, _ in })
        wire.send(#"{"id":1,"method":"_acpmux/context","params":{"sessionId":"s"}}"#) { _ in }
        let read = await inbox.frame(containing: "\"id\":1")
        #expect(read.contains("Read early."))
        for (id, text) in [(2, #""Read concurrently.\nReport briefly.""#), (3, #""""#), (4, "null")] {
            wire.send(#"{"id":\#(id),"method":"_acpmux/context_override","params":{"sessionId":"s","scope":"project","cwd":"/forged","text":\#(text)}}"#) { _ in }
            let reply = await inbox.frame(containing: "\"id\":\(id)")
            #expect(reply.contains("\"saved\":true"))
        }
        wire.send(#"{"id":5,"method":"_acpmux/context","params":{"sessionId":"another"}}"#) { _ in }
        let refused = await inbox.frame(containing: "\"id\":5")
        #expect(refused.contains("remote.unsupported"))
        let edits = await client.edits
        #expect(edits.map(\.0) == ["project", "project", "project"])
        #expect(edits.map(\.1) == ["Read concurrently.\nReport briefly.", "", nil])
        #expect(await client.reads == 1)
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func readOnlyWiresRefuseContextReadsAndEdits() async throws {
        let client = Client(readOnly: true)
        let wire = RemoteAcpmuxWire(client: client, session: "s")
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        try await wire.open(onFrame: { inbox.deliver([$0]) }, onClose: { _, _ in })
        for (id, method) in [(1, "_acpmux/context"), (2, "_acpmux/context_override")] {
            wire.send(#"{"id":\#(id),"method":"\#(method)","params":{"sessionId":"s","scope":"user","text":"edit"}}"#) { _ in }
            let reply = await inbox.frame(containing: "\"id\":\(id)")
            #expect(reply.contains("agent_session.read_only"))
        }
        #expect(await client.reads == 0)
        #expect(await client.edits.isEmpty)
        wire.cancel(code: 1000, reason: "test complete")
    }
}
