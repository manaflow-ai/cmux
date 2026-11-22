import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent pane on the shared page host (plans/cmux-next/react-pages.md, agent pane move P1):
/// the page at `cmux-page://cmux.agent/` reaches only the `cmux.agent.*` ops that replace the
/// old `agentSession` methods, through pane-protocol envelopes, and each op does what its old
/// method did.
@MainActor
@Suite struct AgentPageProviderTests {
    private final class Box {
        var model: AgentPaneModel?
        var prepared: [AgentPaneRequest] = []
    }

    private func router(_ model: AgentPaneModel?) -> (PageRouter, Box) {
        let box = Box()
        box.model = model
        let provider = AgentPageProvider { request in
            box.prepared.append(request)
            return box.model
        }
        return (PageRouter(descriptor: .agent, routes: [PageRoute(prefix: "cmux.agent.", provider: provider)]), box)
    }

    private func call(_ router: PageRouter, _ op: String, _ params: JSONValue = .object([:])) async -> JSONValue {
        await router.handle(["t": "call", "id": 1, "op": .string(op), "params": params])
    }

    @Test func theAgentPageHasItsOwnOrigin() {
        #expect(PageDescriptor.agent.origin == "cmux-page://cmux.agent")
        #expect(PageDescriptor.agent.owns(URL(string: "cmux-page://cmux.agent/")))
        #expect(!PageDescriptor.agent.owns(URL(string: "cmux-page://cmux.agentx/")))
        #expect(!PageDescriptor.agent.owns(URL(string: "cmux-agent://pane/")))
    }

    /// The page opens no connection (the native transport carries acpmux) and frames only loopback
    /// previews and the render frame (`AgentPaneRenderFrame`); nothing else on the network.
    @Test func theAgentPageCSPAllowsOnlyLoopback() {
        let header = PageDescriptor.agent.csp.header
        #expect(header.contains("connect-src 'none'"))
        #expect(header.contains("frame-src cmux-agent://render http://localhost:* http://127.0.0.1:* https://localhost:* https://127.0.0.1:*"))
        #expect(header.hasPrefix("default-src 'none'"))
    }

    /// The header is the one webviews/test/agent-pane-locale.test.ts serves the built pane with,
    /// so that test proves the locale files load under the app's real policy.
    @Test func theAgentPageCSPIsTheOneThePaneLocaleTestServes() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CmuxNextAgentPaneTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CmuxNext
            .deletingLastPathComponent() // macOS
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
            .appending(path: "webviews/test/fixtures/agent-page-csp.txt")
        #expect(PageDescriptor.agent.csp.header == (try String(contentsOf: fixture, encoding: .utf8)))
    }

    /// The page reaches nothing outside its namespace: no shared native op, no other page's ops.
    @Test func opsOutsideTheAgentNamespaceAreRefused() async {
        let (router, box) = router(AgentPaneModel(host: MockAgentPaneHost()))
        for op in ["cmux.app.action.run", "cmux.app.clipboard.write", "cmux.history.list", "cmux.agentx.handshake", "handshake"] {
            let reply = await call(router, op)
            #expect(reply["t"]?.stringValue == "err", "\(op)")
            #expect(reply["code"]?.stringValue == "cmux.protocol.unknown_op", "\(op)")
        }
        #expect(box.prepared.isEmpty)
    }

    /// An op inside the namespace that the old bridge never had is refused before the model.
    @Test func unknownAgentOpsAreRefusedBeforeTheModel() async {
        let (router, box) = router(AgentPaneModel(host: MockAgentPaneHost()))
        for op in ["cmux.agent.chat.prompt", "cmux.agent.ready", "cmux.agent.chat.persistSession", "cmux.agent."] {
            let reply = await call(router, op)
            #expect(reply["code"]?.stringValue == "cmux.protocol.unknown_op", "\(op)")
        }
        #expect(box.prepared.isEmpty)
    }

    @Test func inspectorExportUsesTheSharedPageHostAndPreservesCancellation() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var saved: [(String, String)] = []
        model.onSaveLog = { text, name in
            saved.append((text, name))
            return false
        }
        let (router, box) = router(model)
        let reply = await call(router, "cmux.agent.pane.saveLog", ["text": "{}\n", "suggestedName": "../trace.jsonl"])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(reply["value"]?.boolValue == false)
        #expect(saved.count == 1)
        #expect(saved.first?.0 == "{}\n")
        #expect(saved.first?.1 == "trace.jsonl")
        #expect(box.prepared == [.saveLog(text: "{}\n", suggestedName: "trace.jsonl")])
    }

    @Test func theHandshakeOpAnswersWithTheHandshake() async {
        let (router, box) = router(AgentPaneModel(host: MockAgentPaneHost()))
        let reply = await call(router, "cmux.agent.handshake")
        #expect(reply["t"]?.stringValue == "ok")
        #expect(reply["value"]?["transport"]?.stringValue == "mock")
        #expect(box.prepared == [.ready])
        _ = await call(router, "cmux.agent.handshake", ["reconnect": true])
        #expect(box.prepared.last == .reconnect)
    }

    @Test func blankChatProjectControlsReachTheSharedPageHost() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), allowsTabConversion: true)
        model.onListProjects = { _ in ["/project"] }
        model.onBrowseProject = { "/chosen" }
        var imported = false
        model.onImportAndSync = { imported = true }
        let (router, _) = router(model)

        let listed = await call(router, "cmux.agent.project.list")
        #expect(listed["value"]?["projects"] == .array([.string("/project")]))
        let browsed = await call(router, "cmux.agent.project.browse")
        #expect(browsed["value"]?["cwd"]?.stringValue == "/chosen")
        let reply = await call(router, "cmux.agent.onboarding.importAndSync")
        #expect(reply["t"]?.stringValue == "ok")
        #expect(imported)
    }

    @Test func sessionPersistRecordsTheSession() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let (router, _) = router(model)
        let reply = await call(router, "cmux.agent.session.persist", ["sessionId": "s-7"])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(model.sessionId == "s-7")
    }

    /// A known op with params the old parser refuses is an invalid-params error, not a model call.
    @Test func badParamsAreInvalidParams() async {
        let (router, box) = router(AgentPaneModel(host: MockAgentPaneHost()))
        let reply = await call(router, "cmux.agent.session.persist", ["sessionId": ""])
        #expect(reply["code"]?.stringValue == "cmux.protocol.invalid_params")
        #expect(box.prepared.isEmpty)
    }

    /// The model's refusal reaches the page as an error envelope with the model's code and message.
    @Test func aModelRefusalIsAnErrorEnvelope() async {
        // action.run is allowed only on a new tab page; a chat tab refuses it.
        let (router, _) = router(AgentPaneModel(host: MockAgentPaneHost(), sessionId: "s1"))
        let reply = await call(router, "cmux.agent.action.run", ["id": "palette.welcomeChecklist"])
        #expect(reply["t"]?.stringValue == "err")
        #expect(reply["code"]?.stringValue == "unsupported")
        #expect(reply["message"]?.stringValue?.isEmpty == false)
    }

    /// A closed tab has no model: the call fails as closed and the page may retry after a reload.
    @Test func aClosedPaneFailsAsClosed() async {
        let (router, _) = router(nil)
        let reply = await call(router, "cmux.agent.handshake")
        #expect(reply["code"]?.stringValue == PageError.closed.code)
    }

    /// Every op the page uses is routed: none of them is refused as unknown.
    @Test func everyAgentOpIsRouted() async {
        let (router, _) = router(AgentPaneModel(host: MockAgentPaneHost()))
        for op in AgentPageOps.all {
            let reply = await call(router, op)
            #expect(reply["code"]?.stringValue != "cmux.protocol.unknown_op", "\(op)")
        }
    }
}
