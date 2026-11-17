import CmuxNextCloud
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The picker's model, effort and account in a Cloud start (cmux-tui/docs/model-connections.md), and
/// the Set up Cloud card's `cloud.setUp`: its click runs the way in, and once a connection serves the
/// family the start goes again on that click, with no retyping.
@Suite
@MainActor
struct AgentPaneCloudSetUpTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func code(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }

    @Test func theStartCarriesThePickersEffortAndAccountToTheMachinesSeed() throws {
        let key = UUID().uuidString
        let start = try #require(AgentPaneCloudStart(params: ["task": "fix it", "key": key, "home": true, "harness": "claude",
                                                              "model": "claude-opus-5-5", "effort": "high", "account": "claude-login"]))
        #expect(start.effort == "high" && start.account == "claude-login")
        let seed = start.seed(cwd: "/root/work")
        #expect(seed.harness == "claude" && seed.model == "claude-opus-5-5" && seed.effort == "high")
        // An account that is no connection id refuses the start.
        #expect(AgentPaneCloudStart(params: ["task": "fix it", "key": key, "home": true, "account": "a b\r\nx: y"]) == nil)
        #expect(AgentPaneCloudStart(params: ["task": "fix it", "key": key, "home": true])?.account == nil)
    }

    @Test func aSetUpClickKeepsItsClickForTheStartOnceAConnectionServes() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        var starts: [AgentPaneCloudStart] = []
        model.onCloudStartChat = { start in
            starts.append(start)
            return AgentPaneReply.success(["machine": "cloud-1"])
        }
        var ran: [(CloudSetup.Action, String)] = []
        model.onCloudSetUp = { action, family in
            ran.append((action, family))
            return true
        }
        let key = UUID().uuidString
        let setUp = AgentPaneRequest(body: ["method": "cloud.setUp", "params": ["key": key, "action": "connectChatGPT", "family": "codex"]])
        // A scripted request runs no way in.
        #expect(Self.code(await model.respond(to: setUp)) == "transport.gesture_required")
        #expect(ran.isEmpty)
        model.transport.gestures.record()
        let reply = await model.respond(to: setUp)
        #expect(reply["ok"] as? Bool == true)
        #expect(ran.map(\.0) == [.connectChatGPT] && ran.map(\.1) == ["codex"])
        // The start goes again on the kept click, with no gesture, once.
        let again = AgentPaneRequest(body: ["method": "cloud.startChat", "params": ["task": "kept prompt", "key": key, "home": true, "signedIn": true]])
        #expect(await model.respond(to: again)["ok"] as? Bool == true)
        #expect(starts.map(\.task) == ["kept prompt"])
    }

    @Test func aSetUpThatEndsWithNoConnectionKeepsNoClick() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        model.onCloudStartChat = { _ in AgentPaneReply.success() }
        model.onCloudSetUp = { _, _ in false }
        let key = UUID().uuidString
        model.transport.gestures.record()
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "cloud.setUp", "params": ["key": key, "action": "openSettings", "family": "claude"]]))
        #expect(Self.code(reply) == "cloud_sign_in_cancelled")
        let again = AgentPaneRequest(body: ["method": "cloud.startChat", "params": ["task": "kept prompt", "key": key, "home": true, "signedIn": true]])
        #expect(Self.code(await model.respond(to: again)) == "cloud_sign_in_cancelled")
    }

    @Test func onlyTheCardsWaysInAndFamiliesAreTaken() {
        let request = { (params: [String: Any]) in AgentPaneRequest(body: ["method": "cloud.setUp", "params": params]) }
        let key = UUID().uuidString
        if case .cloudSetUp(key, "setUpClaude", "claude") = request(["key": key, "action": "setUpClaude", "family": "claude"]) {} else { Issue.record("the card's set up is taken") }
        if case .unsupported = request(["action": "addKey", "family": "claude"]) {} else { Issue.record("a set up with no start key is refused") }
        if case .unsupported = request(["key": key, "action": "rm -rf", "family": "claude"]) {} else { Issue.record("an unknown action is refused") }
        if case .unsupported = request(["key": key, "action": "addKey", "family": "gemini"]) {} else { Issue.record("an unknown family is refused") }
        if case .unsupported = request(["key": "nope", "action": "addKey", "family": "codex"]) {} else { Issue.record("a key that is not a start key is refused") }
    }
}
