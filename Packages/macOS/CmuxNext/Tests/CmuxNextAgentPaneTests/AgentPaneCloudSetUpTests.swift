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

    /// A machine without its own sign-in can offer setup when this Mac can confirm what is missing.
    @Test func aStartWithNothingSigningItsAgentInAsksToSetItUp() async throws {
        let key = UUID().uuidString
        for (harness, family) in [("claude", "claude"), ("codex", "codex")] {
            let start = try #require(AgentPaneCloudStart(params: ["task": "fix it", "key": key, "home": true, "harness": harness, "model": "m"]))
            let unread = await start.needsConnectionReply("not routed", setup: CloudSetup())
            #expect(Self.code(unread) == "cloud_start_failed")
            #expect((unread["error"] as? [String: Any])?["retryable"] as? Bool == true)
            for snapshot in [CloudSetup.Snapshot(personal: [], organization: []), .init(personal: [], organization: [family])] {
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
        model.useCloudSetup(CloudSetup(
            read: { .init(personal: [.init(id: "claude-token", families: ["claude"])], organization: []) },
            run: { action, family, _ in ran.append((action, family)) }
        ))
        let key = UUID().uuidString
        let setUp = AgentPaneRequest(body: ["method": "cloud.setUp", "params": ["key": key, "action": "setUpClaude", "family": "claude"]])
        // A scripted request runs no way in.
        #expect(Self.code(await model.respond(to: setUp)) == "transport.gesture_required")
        #expect(ran.isEmpty)
        model.transport.gestures.record()
        let reply = await model.respond(to: setUp)
        #expect(reply["ok"] as? Bool == true)
        #expect(ran.map(\.0) == [.setUpClaude] && ran.map(\.1) == ["claude"])
        // The start goes again on the kept click, with no gesture, once.
        let again = AgentPaneRequest(body: ["method": "cloud.startChat", "params": ["task": "kept prompt", "key": key, "home": true, "signedIn": true]])
        #expect(await model.respond(to: again)["ok"] as? Bool == true)
        #expect(starts.map(\.task) == ["kept prompt"])
    }

    @Test func automaticClaudeSetupRetriesOnItsSignedInMachine() async throws {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        var retried: AgentPaneCloudStart?
        model.onCloudStartChat = { retried = $0; return AgentPaneReply.success() }
        let setup = CloudSetup(read: { .init(personal: [], organization: []) })
        setup.run = { [weak setup] _, _, machine in
            #expect(machine == nil)
            setup?.claudeSignInCompleted(machine: "vm_b")
        }
        model.useCloudSetup(setup)
        let key = UUID().uuidString
        let original = try #require(AgentPaneCloudStart(params: ["task": "held prompt", "key": key, "home": true]))
        let choice = CloudSetup.Choice.setup(family: "claude", model: nil)
        let refusal = try #require(original.connectionRefusalReply(for: choice))
        #expect(Self.code(refusal) == "cloud_setup_required")
        model.transport.gestures.record()
        let ready = await model.respond(to: AgentPaneRequest(body: ["method": "cloud.setUp", "params": ["key": key, "action": "setUpClaude", "family": "claude"]]))
        #expect(ready["ok"] as? Bool == true)
        let again = AgentPaneRequest(body: ["method": "cloud.startChat", "params": ["task": "held prompt", "key": key, "home": true, "signedIn": true]])
        #expect(await model.respond(to: again)["ok"] as? Bool == true)
        let start = try #require(retried)
        #expect(start.machine == "vm_b" && start.usesMachineLogin)
        let opened = AgentPaneCloudStarted(start: start, chat: nil, workspace: nil, account: [], machineID: "vm_b")
        #expect(opened.start.machine == nil && !opened.start.usesMachineLogin, "the later Repick must use its own machine")
        #expect(opened.start.key == key)
    }

    @Test func aProjectWaitsForItsSizedMachineBeforeOfferingClaudeSetup() async throws {
        let start = AgentPaneCloudStart(task: "held prompt", cwd: "/Users/me/large-project", key: UUID().uuidString)
        let setup = CloudSetup(read: { .init(personal: [], organization: []) })
        let readiness = await setup.plannerReadiness(for: start)
        #expect(readiness.choice == .setup(family: "claude", model: nil))
        #expect(start.connectionRefusalReply(for: readiness.choice) == nil)

        let bytes = CloudChatSize.sm.diskBytes
        let sized = try start.sized(.passed(bytes: bytes, size: .md), local: "/Users/me/large-project")
        #expect(sized.size == .md && sized.folderBytes == bytes)
        #expect(sized.machine == nil)
        let reply = await sized.needsConnectionReply("sign-in required", machine: "vm_sized", setup: setup)
        #expect(Self.code(reply) == "cloud_setup_required")
        let details = (reply["error"] as? [String: Any])?["details"] as? [String: Any]
        #expect(details?["machine"] as? String == "vm_sized")
    }

    @Test(arguments: ["openrouter", "providers/custom"])
    func aLocalOnlyModelGetsARefusalInsteadOfACloudSetupWait(harness: String) async throws {
        let endpoint = try #require(CloudSetup.Connection(json: ["id": "providers/custom", "kind": "endpoint"]))
        let setup = CloudSetup(read: { .init(personal: [endpoint], organization: []) })
        let start = try #require(AgentPaneCloudStart(params: [
            "task": "held prompt", "key": UUID().uuidString, "home": true, "harness": harness,
        ]))
        let (choice, _) = await setup.launchReadiness(for: start)
        let reply = try #require(start.connectionRefusalReply(for: choice))
        #expect(Self.code(reply) == "cloud_model_local_only")
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["userMessage"] as? String == AgentPaneCloudStart.localOnlyMessage)
        #expect(error["retryable"] as? Bool == false)
    }

    @Test func aSetUpThatEndsWithNoConnectionKeepsNoClick() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        model.onCloudStartChat = { _ in AgentPaneReply.success() }
        model.onCloudSetUp = { _, _, _, _ in nil }
        let key = UUID().uuidString
        model.transport.gestures.record()
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "cloud.setUp", "params": ["key": key, "action": "openSettings", "family": "claude"]]))
        #expect(Self.code(reply) == "cloud_sign_in_cancelled")
        let again = AgentPaneRequest(body: ["method": "cloud.startChat", "params": ["task": "kept prompt", "key": key, "home": true, "signedIn": true]])
        #expect(Self.code(await model.respond(to: again)) == "cloud_sign_in_cancelled")
    }

    /// CMUX-662: a new chat's picker reads what serves Cloud with no gesture; a pane with no Cloud refuses it.
    @Test func setupStateAnswersTheServedFamiliesWithNoGesture() async throws {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        let request = AgentPaneRequest(body: ["method": "cloud.setup.state", "params": [:] as [String: Any]])
        if case .cloudSetupState = request {} else { Issue.record("the read is taken") }
        #expect(Self.code(await model.respond(to: request)) == "unsupported")
        model.onCloudStartChat = { _ in AgentPaneReply.success() }
        model.onCloudServed = { _, _ in .init(families: ["claude": false, "codex": true], reasons: ["claude": .off]) }
        let reply = await model.respond(to: request)
        #expect(reply["ok"] as? Bool == true)
        let families = try #require((reply["value"] as? [String: Any])?["families"] as? [String: Bool])
        #expect(families == ["claude": false, "codex": true])
        #expect((reply["value"] as? [String: Any])?["runnableFamilies"] as? [String] == ["claude", "codex"])
        #expect((reply["value"] as? [String: Any])?["reasons"] as? [String: String] == ["claude": "off"])
        // The app's wiring: the one CloudSetup answers it; none refuses it again.
        model.useCloudSetup(CloudSetup(read: { .init(personal: [.init(id: "claude-token", families: ["claude"])], organization: []) }))
        let wired = (await model.respond(to: request))["value"] as? [String: Any]
        #expect(wired?["families"] as? [String: Bool] == ["claude": true, "codex": false])
        #expect(wired?["reasons"] as? [String: String] == ["codex": "none"])
        model.useCloudSetup(nil)
        #expect(Self.code(await model.respond(to: request)) == "unsupported")
    }

    /// CMUX-662 review: the picker's Connect belongs to no start. It needs the click, opens the way in, keeps no
    /// click (a start's kept click still goes again) and works in an empty chat whose local session opened first.
    @Test func connectOpensTheWayInOnItsClickAndKeepsNoClick() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "local-empty")
        model.onCloudStartChat = { _ in AgentPaneReply.success() }
        var opened: [String] = []
        model.onCloudConnect = { family, _, _, _ in opened.append(family) }
        let connect = AgentPaneRequest(body: ["method": "cloud.connect", "params": ["family": "codex"]])
        #expect(Self.code(await model.respond(to: connect)) == "transport.gesture_required")
        #expect(opened.isEmpty)
        model.transport.gestures.record()
        #expect(await model.respond(to: connect)["ok"] as? Bool == true)
        #expect(opened == ["codex"])
        // A start's kept click is not replaced by a Connect.
        let key = UUID().uuidString
        model.keepCloudSignInGrant(key, generation: model.cloudSignInGeneration)
        model.transport.gestures.record()
        _ = await model.respond(to: connect)
        #expect(model.takeCloudSignInGrant(key) != nil)
    }

    @Test func pickerConnectAcceptsCatalogFamiliesTheGatewayDoesNotRun() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "local-empty")
        model.onCloudStartChat = { _ in AgentPaneReply.success() }
        let setup = CloudSetup()
        var opened: [String] = []
        setup.openConnectionSettings = { family, _, _, _, _ in opened.append(family) }
        model.useCloudSetup(setup)
        let request = { (family: String) in AgentPaneRequest(body: ["method": "cloud.connect", "params": ["family": family]]) }
        #expect(Self.code(await model.respond(to: request("google"))) == "transport.gesture_required")
        #expect(opened.isEmpty)
        model.transport.gestures.record()
        #expect(Self.code(await model.respond(to: request("gemini&focus=general"))) == "unsupported")
        #expect(await model.respond(to: request("google"))["ok"] as? Bool == true)
        #expect(opened == ["google"])
        #expect(Self.code(await model.respond(to: request("claude"))) == "transport.gesture_required")
    }

    @Test func aDraftAndItsHeldSendOnlyOpenSettingsForTheSelectedOwnedMachine() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        model.onCloudStartChat = { _ in AgentPaneReply.success() }
        let setup = CloudSetup(read: { .init(personal: [.init(id: "claude-token", families: ["claude"])], organization: []) })
        setup.ownsMachine = { ["vm_a", "vm_b"].contains($0) }
        var opened: [(String, String?, Bool)] = []
        setup.openConnectionSettings = { family, machine, held, _, _ in opened.append((family, machine, held)) }
        model.useCloudSetup(setup)
        let connect = { (machine: String) in AgentPaneRequest(body: ["method": "cloud.connect", "params": ["family": "claude", "machine": machine]]) }
        let key = UUID().uuidString
        let retry = { (machine: String) in
            AgentPaneRequest(body: ["method": "cloud.setUp", "params": ["key": key, "action": "setUpClaude", "family": "claude", "machine": machine]])
        }
        model.transport.gestures.record()
        #expect(Self.code(await model.respond(to: connect("shared"))) == "unsupported")
        #expect(Self.code(await model.respond(to: retry("shared"))) == "unsupported")
        #expect(opened.isEmpty)
        #expect(await model.respond(to: connect("vm_b"))["ok"] as? Bool == true)
        model.transport.gestures.record()
        #expect(await model.respond(to: retry("vm_b"))["ok"] as? Bool == true)
        #expect(opened.map { $0.1 } == ["vm_b", "vm_b"])
        #expect(opened.map { $0.2 } == [false, true])
        #expect(model.takeCloudSignInGrant(key) != nil)
    }

    @Test func cloudRenewalUsesTheCurrentTabAndRequiresAnOwnerClick() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "cloud-chat")
        model.remoteChat = true
        model.tabKey = { "cloud-tab" }
        var opened: [String] = []
        var authorized = false
        model.onCloudConnect = { family, machine, _, recoverySession in
            #expect(recoverySession == "cloud-chat")
            opened.append("\(family):\(machine ?? "")") }
        model.mayRecoverCloudConnection = { $0 == "cloud-tab" && authorized ? "vm_b" : nil }
        let connect = AgentPaneRequest(body: ["method": "cloud.connect", "params": ["family": "claude", "machine": "vm_b"]])
        #expect(Self.code(await model.respond(to: connect)) == "transport.gesture_required")
        model.transport.gestures.record()
        #expect(Self.code(await model.respond(to: connect)) == "unsupported")
        #expect(opened.isEmpty)
        authorized = true
        let wrongMachine = AgentPaneRequest(body: ["method": "cloud.connect", "params": ["family": "claude", "machine": "vm_a"]])
        model.transport.gestures.record()
        #expect(Self.code(await model.respond(to: wrongMachine)) == "unsupported")
        #expect(opened.isEmpty)
        model.transport.gestures.record()
        #expect(await model.respond(to: connect)["ok"] as? Bool == true)
        #expect(opened == ["claude:vm_b"])
    }

    @Test func aSetupGrantKeepsTheEnvironmentAndTheSelectedMachine() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        let key = UUID().uuidString
        let environment = "env_0123456789abcdef01234567"
        model.onCloudStartChat = { start in
            #expect(start.machine == "vm_b")
            #expect(start.environment == environment)
            return AgentPaneReply.success()
        }
        model.ownsCloudConnectionMachine = { $0 == "vm_b" }
        model.onCloudSetUp = { _, _, machine, scope in
            #expect(machine == "vm_b" && scope == environment)
            return .init(machine: machine, usesMachineLogin: true, environment: scope, bindsEnvironment: true)
        }
        model.transport.gestures.record()
        let setup = AgentPaneRequest(body: ["method": "cloud.setUp", "params": [
            "key": key, "action": "setUpClaude", "family": "claude", "machine": "vm_b", "environment": environment
        ]])
        #expect(await model.respond(to: setup)["ok"] as? Bool == true)
        let changed = AgentPaneRequest(body: ["method": "cloud.startChat", "params": [
            "key": key, "task": "original prompt", "home": true, "signedIn": true
        ]])
        #expect(Self.code(await model.respond(to: changed)) == "cloud_sign_in_cancelled")
        model.transport.gestures.record()
        #expect(await model.respond(to: setup)["ok"] as? Bool == true)
        let retry = AgentPaneRequest(body: ["method": "cloud.startChat", "params": [
            "key": key, "task": "original prompt", "home": true, "signedIn": true, "environment": environment
        ]])
        #expect(await model.respond(to: retry)["ok"] as? Bool == true)
    }

    @Test func accountSignInLeavesTheSendInItsExplicitEnvironment() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: nil)
        let key = UUID().uuidString
        let environment = "env_0123456789abcdef01234567"
        model.onCloudStartChat = { start in
            #expect(start.environment == environment)
            return AgentPaneReply.success()
        }
        model.keepCloudSignInGrant(key, generation: model.cloudSignInGeneration)
        let request = AgentPaneRequest(body: ["method": "cloud.startChat", "params": [
            "key": key, "task": "original prompt", "home": true, "signedIn": true, "environment": environment
        ]])
        #expect(await model.respond(to: request)["ok"] as? Bool == true)
    }

    @Test func setupRequiresAnActionAndAValidFamily() {
        let request = { (params: [String: Any]) in AgentPaneRequest(body: ["method": "cloud.setUp", "params": params]) }
        let key = UUID().uuidString
        if case .cloudSetUp(key, "setUpClaude", "claude", nil, nil) = request(["key": key, "action": "setUpClaude", "family": "claude"]) {} else { Issue.record("the card's set up is taken") }
        if case .unsupported = request(["action": "addKey", "family": "claude"]) {} else { Issue.record("a set up with no start key is refused") }
        if case .unsupported = request(["key": key, "action": "rm -rf", "family": "claude"]) {} else { Issue.record("an unknown action is refused") }
        if case .cloudSetUp(key, "openSettings", "providers/custom", nil, nil) = request(["key": key, "action": "openSettings", "family": "providers/custom"]) {} else { Issue.record("a named harness profile can open settings") }
        if case .unsupported = request(["key": key, "action": "addKey", "family": "providers//custom"]) {} else { Issue.record("a malformed family is refused") }
        if case .unsupported = request(["key": "nope", "action": "addKey", "family": "codex"]) {} else { Issue.record("a key that is not a start key is refused") }
    }
}
