import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Workflow agent transcript reads are a bounded, read-only relay. The page may name the
/// selected chat and the daemon's workflow cursor, but it cannot smuggle control metadata or
/// another request into the native socket.
@Suite(.serialized)
@MainActor
struct AgentPaneSubagentTranscriptRelayTests {
    static func frame(id: Int, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/subagent_transcript","params":\#(params)}"#
    }

    @Test func thePaneAllowsOnlyTranscriptCursorParams() {
        func object(_ params: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(Self.frame(id: 1, params: params).utf8))) as? [String: Any]
        }
        let valid = [
            #"{"sessionId":"s","runId":"wf_run","agentId":"agent","before":3,"after":7,"limit":25}"#,
            #"{"sessionId":"s","runId":"wf_run","agentId":"agent"}"#,
        ]
        for params in valid {
            guard case .send = AcpmuxPaneMethods.decide(Self.frame(id: 1, params: params), isFirst: false, localAppToken: nil) else {
                Issue.record("the relay refused the transcript read: \(params)")
                continue
            }
            #expect(!AcpmuxPaneMethods.breaksParamsRule(object(params), modeFields: []), "\(params)")
        }
        // `_meta` is acpmux's control/provenance channel, never a transcript cursor field.
        for extra in [
            #""_meta":{"acpmux":{"via":"web"}}"#,
            #""foo":"bar""#,
            #""maxBytes":1"#,
        ] {
            let params = #"{"sessionId":"s","runId":"wf_run","agentId":"agent",\#(extra)}"#
            #expect(AcpmuxPaneMethods.breaksParamsRule(object(params), modeFields: []), "\(extra)")
        }
        #expect(AcpmuxPaneMethods.breaksParamsRule(object(#"["s"]"#), modeFields: []))
    }

    @Test(.timeLimit(.minutes(1))) func anAllowedTranscriptReadReachesAcpmuxOnlyForTheSelectedChat() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let reads = { server.peers.first?.frames.filter { $0.contains("_acpmux/subagent_transcript") } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, params: #"{"sessionId":"s","runId":"wf_run","agentId":"agent","after":2,"limit":25}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":1"#)
        let sent = try #require(reads().first, "the read never reached acpmux")
        let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params as NSDictionary == ["sessionId": "s", "runId": "wf_run", "agentId": "agent", "after": 2, "limit": 25] as NSDictionary)

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, params: #"{"sessionId":"other","runId":"wf_run","agentId":"agent"}"#)]) == .sessionNotInPane,
                "a transcript read cannot escape the selected chat")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, params: #"{"sessionId":"s","runId":"wf_run","agentId":"agent","_meta":{"acpmux":{}}}"#)]) == .intentInvalid)
        #expect(reads().count == 1, "a refused read reached acpmux: \(reads())")
    }
}
