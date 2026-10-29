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
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/session/auth","params":\#(params)}"#
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
            #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.object(params), modeFields: []), Comment(rawValue: params))
        }

        let invalid = [
            #"{}"#,
            #"null"#,
            #"[]"#,
            #"{"sessionId":null}"#,
            #"{"target":null}"#,
            #"{"sessionId":"s","target":{"harness":"claude"}}"#,
            #"{"sessionId":""}"#,
            #"{"sessionId":"s","refresh":"true"}"#,
            #"{"target":{}}"#,
            #"{"target":{"harness":"claude","extra":"nope"}}"#,
            #"{"target":{"harness":"claude","host":""}}"#,
            #"{"target":{"harness":"claude","routeId":7}}"#,
            #"{"target":{"harness":"claude"},"refresh":1}"#,
            #"{"target":{"harness":"claude","routeId":"Team-router"}}"#,
            #"{"target":{"harness":"claude","routeId":"route/id"}}"#,
            #"{"target":{"harness":"claude"},"host":"other"}"#,
            #"{"target":{"harness":"claude","sessionId":"other"}}"#,
            #"{"target":{"harness":"claude","host":null}}"#,
            #"{"target":{"harness":"claude","routeId":null}}"#,
            #"{"target":{"harness":"claude"},"refresh":null}"#,
        ]
        for params in invalid {
            #expect(AcpmuxPaneMethods.breaksParamsRule(Self.object(params), modeFields: []), Comment(rawValue: params))
        }
        #expect(AcpmuxPaneMethods.breaksParamsRule(["method": "_acpmux/session/auth"], modeFields: []))
    }

    @Test func duplicateOrAliasedIdentityKeysAreRefusedBeforeDecoding() {
        for params in [
            #"{"target":{"harness":"claude","host":"known","host":"other"}}"#,
            #"{"target":{"harness":"claude","host":"known","h\u006fst":"other"}}"#,
            #"{"sessionId":"owned","sessionId":"other"}"#,
        ] {
            guard case .refuse(.duplicateKey, _, _) = AcpmuxPaneMethods.decide(
                Self.frame(params: params), isFirst: false, localAppToken: nil
            ) else {
                Issue.record("duplicate identity was not refused: \(params)")
                continue
            }
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

    @Test func targetHostMustBeInTheDaemonPeerSnapshot() throws {
        let known = try #require(Self.object(#"{"target":{"harness":"claude","host":"gcp-agent-lane-1"}}"#))
        let unknown = try #require(Self.object(#"{"target":{"harness":"claude","host":"not-a-peer"}}"#))
        let sessions = AcpmuxPaneSessions()
        #expect(AgentPaneTransport.sessionRefusal(known, sessions: sessions,
                                                   peerHosts: ["gcp-agent-lane-1"]) == nil)
        guard case .refuse(.intentInvalid, _, _) = AgentPaneTransport.sessionRefusal(unknown, sessions: sessions,
                                                                                       peerHosts: ["gcp-agent-lane-1"]) else {
            Issue.record("an unknown target host was not refused")
            return
        }
        guard case .refuse(.intentInvalid, _, _) = AgentPaneTransport.sessionRefusal(known, sessions: sessions) else {
            Issue.record("an unavailable peer snapshot did not fail closed")
            return
        }
    }

    @Test func authEvidenceAndInitializeFeaturesReachThePageUnchanged() throws {
        let ids = AcpmuxRequestIds()
        let authID = try #require(ids.begin(pageID: "7", method: "_acpmux/session/auth"))
        let auth = #"{"state":"expired","source":"turn","evidenceAt":1761630000000,"detail":"OAuth token has expired","harness":"claude","host":null,"routeId":null,"fromSessionId":"owned","login":{"kind":"terminal","command":"claude /login","host":null}}"#
        guard case .page(let text, _, let method) = ids.toPage(
            #"{"jsonrpc":"2.0","id":\#(authID),"result":\#(auth)}"#
        ) else {
            Issue.record("auth reply did not reach the page")
            return
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let expected = try #require(try JSONSerialization.jsonObject(with: Data(auth.utf8)) as? [String: Any])
        #expect(method == "_acpmux/session/auth")
        let received = try #require(object["result"] as? NSDictionary)
        #expect(received == expected as NSDictionary)
        #expect(object["id"] as? Int == 7)

        let initializeID = try #require(ids.begin(pageID: "8", method: "initialize"))
        guard case .page(_, let initialized, _) = ids.toPage(
            #"{"jsonrpc":"2.0","id":\#(initializeID),"result":{"_meta":{"acpmux":{"features":["sessionAuth"]}}}}"#
        ) else {
            Issue.record("initialize reply did not reach the page")
            return
        }
        let result = try #require(initialized["result"] as? [String: Any])
        let meta = try #require(result["_meta"] as? [String: Any])
        let acpmux = try #require(meta["acpmux"] as? [String: Any])
        #expect(acpmux["features"] as? [String] == ["sessionAuth"])
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
