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

    /// cmux#45773: a start whose machine has nothing that signs its agent in, and that carried no connection, asks the
    /// person to set the agent up (Set up Cloud for Claude or Codex), whatever this Mac's connections read; never the
    /// dead-end route text. Only an agent Cloud cannot set up gets that text.
    @Test func aStartWithNothingSigningItsAgentInAsksToSetItUp() async throws {
        let key = UUID().uuidString
        for (harness, family) in [("claude", "claude"), ("codex", "codex")] {
            let start = try #require(AgentPaneCloudStart(params: ["task": "fix it", "key": key, "home": true, "harness": harness, "model": "m"]))
            for snapshot in [CloudSetup.Snapshot(personal: nil, organization: nil), .init(personal: [], organization: [family])] {
                let reply = await start.needsConnectionReply("not routed", setup: CloudSetup(read: { snapshot }))
                #expect(Self.code(reply) == "cloud_setup_required")
                let details = (reply["error"] as? [String: Any])?["details"] as? [String: Any]
                #expect(details?["family"] as? String == family && details?["model"] as? String == "m")
            }
        }
        let other = try #require(AgentPaneCloudStart(params: ["task": "fix it", "key": key, "home": true, "harness": "gemini"]))
        #expect(Self.code(await other.needsConnectionReply("not routed", setup: CloudSetup())) == "cloud_start_failed")
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
        // The model picker's set up button (cmux#51731) sends no key: taken, keeping no click.
        if case .cloudSetUp(nil, "addKey", "claude") = request(["action": "addKey", "family": "claude"]) {} else { Issue.record("the picker's set up is taken") }
        if case .unsupported = request(["key": key, "action": "rm -rf", "family": "claude"]) {} else { Issue.record("an unknown action is refused") }
        if case .unsupported = request(["key": key, "action": "addKey", "family": "gemini"]) {} else { Issue.record("an unknown family is refused") }
        if case .unsupported = request(["key": "nope", "action": "addKey", "family": "codex"]) {} else { Issue.record("a key that is not a start key is refused") }
    }

    /// cmux#51731: the model picker with Cloud picked reads which families Cloud runs now, and its set up button runs the
    /// way in on any page (a started Cloud chat too), keeping no click for any start.
    @Test func thePickerReadsCloudsFamiliesAndSetsOneUpWithNoStart() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "started")
        let empty = await model.respond(to: AgentPaneRequest(body: ["method": "cloud.setupState"]))
        #expect(empty["ok"] as? Bool == true && ((empty["value"] as? [String: Any])?["families"]) == nil)
        model.onCloudSetupState = { ["claude": true, "codex": false] }
        let state = await model.respond(to: AgentPaneRequest(body: ["method": "cloud.setupState"]))
        #expect(((state["value"] as? [String: Any])?["families"] as? [String: Bool]) == ["claude": true, "codex": false])
        var ran: [(CloudSetup.Action, String)] = []
        model.onCloudSetUp = { action, family in
            ran.append((action, family))
            return true
        }
        let setUp = AgentPaneRequest(body: ["method": "cloud.setUp", "params": ["action": "connectChatGPT", "family": "codex"]])
        #expect(Self.code(await model.respond(to: setUp)) == "transport.gesture_required")
        model.transport.gestures.record()
        #expect(await model.respond(to: setUp)["ok"] as? Bool == true)
        #expect(ran.map(\.0) == [.connectChatGPT] && ran.map(\.1) == ["codex"])
    }

    @Test func servingNamesEachFamilyCloudRunsNow() async {
        let snapshot = CloudSetup.Snapshot(personal: [.init(id: "c", families: ["claude"])], organization: [])
        #expect(await CloudSetup(read: { snapshot }).serving() == ["claude": true, "codex": false])
        #expect(await CloudSetup().serving() == nil)
    }
}
