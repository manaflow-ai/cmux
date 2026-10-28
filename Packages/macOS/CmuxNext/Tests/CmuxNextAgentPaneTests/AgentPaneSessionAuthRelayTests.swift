import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The app-native relay contract for the read-only session/auth preflight. The page may
/// ask about an existing pane session or a selected harness/peer/route target, but it
/// may never smuggle a second identity, an endpoint or a command through the host.
@Suite(.serialized)
@MainActor
struct AgentPaneSessionAuthRelayTests {
    static func frame(id: Int = 1, params: String) -> String {
        #"{"jsonrpc":"2.0","id":#(id),"method":"_acpmux/session/auth","params":#(params)}"#
    }

    static func object(_ params: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(Self.frame(params: params).utf8))) as? [String: Any]
    }

    @Test func sessionAuthUsesTheExactSessionOrTargetShape() {
        let valid = [
            #"{"sessionId":"s"}"#,
            #"{"sessionId":"s","refresh":true}"#,
            #"{"target":{"harness":"claude"}}"#,
            #"{"target":{"harness":"codex","host":"gcp-codex-lane-1","routeId":"team-router"},"refresh":false}"#,
        ]
        for params in valid {
            #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.object(params), modeFields: []), params)
        }

        let invalid = [
            #"{}"#,
            #"{"sessionId":"s","target":{"harness":"claude"}}"#,
            #"{"sessionId":""}"#,
            #"{"sessionId":"s","refresh":"true"}"#,
            #"{"target":{}}"#,
            #"{"target":{"harness":"claude","extra":"nope"}}"#,
            #"{"target":{"harness":"claude","host":""}}"#,
            #"{"target":{"harness":"claude","host":"peer name"}}"#,
            #"{"target":{"harness":"claude","routeId":7}}"#,
            #"{"target":{"harness":"claude"},"refresh":1}"#,
        ]
        for params in invalid {
            #expect(AcpmuxPaneMethods.breaksParamsRule(Self.object(params), modeFields: []), params)
        }
    }

    @Test func thePageMaySendSessionAuthReadOnly() {
        guard case .send = AcpmuxPaneMethods.decide(Self.frame(params: #"{"sessionId":"s"}"#),
                                                     isFirst: false, localAppToken: nil) else {
            Issue.record("the pane refused the session/auth read")
            return
        }
        #expect(!AcpmuxPaneMethods.needsGesture(Self.frame(params: #"{"target":{"harness":"claude"}}"#),
                                                 options: AcpmuxPermissionOptions()))
    }

    @Test(.timeLimit(.minutes(1))) func aSessionQueryIsScopedToThePane() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("owned")

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, params: #"{"sessionId":"other"}"#)])
                == .sessionNotInPane)
        #expect(server.peers.first?.frames.contains { $0.contains("_acpmux/session/auth") } != true)

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, params: #"{"sessionId":"owned"}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":3"#)
        #expect(server.peers.first?.frames.contains { $0.contains("_acpmux/session/auth") } == true)
    }
}

