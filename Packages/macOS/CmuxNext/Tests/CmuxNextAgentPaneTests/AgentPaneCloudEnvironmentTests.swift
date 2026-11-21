import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneCloudEnvironmentTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func saveForwardsNullAndWriteOnlySecretsOnlyWithTheSaveGesture() async throws {
        let model = AgentPaneModel(host: NoHost())
        var calls: [AgentPaneCloudEnvironmentRequest] = []
        model.onCloudEnvironment = { request in
            calls.append(request)
            return AgentPaneReply.success(["id": "env_default"])
        }
        let request = AgentPaneRequest(body: ["method": "cloud.environment.update", "params": [
            "id": "env_default", "patch": ["setup_script": NSNull(), "set_secrets": [["name": "TOKEN", "value": "write-only"]]],
        ]])
        #expect(await model.respond(to: request)["ok"] as? Bool == false)
        #expect(calls.isEmpty)
        model.transport.gestures.record(click: true)
        #expect(await model.respond(to: request)["ok"] as? Bool == true)
        #expect(calls.count == 1)
        let sent = try #require(calls.first)
        #expect(sent.action == "update")
        #expect(sent.params["patch"]?["setup_script"] == .null)
        #expect(sent.params["patch"]?["set_secrets"] == .array([.object(["name": .string("TOKEN"), "value": .string("write-only")])]))
        #expect(String(describing: request) == "cloudEnvironment")
        #expect(await model.respond(to: request)["ok"] as? Bool == false)
        #expect(calls.count == 1)
    }

    /// New environment… (the composer's Environment chip) creates one only on the person's click.
    @Test func createForwardsOnlyWithAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var actions: [String] = []
        model.onCloudEnvironment = { request in actions.append(request.action); return AgentPaneReply.success(["id": "env_new"]) }
        #expect(AgentPageOps.methods["cloud.environment.create"] == "cloud.environment.create")
        let request = AgentPaneRequest(body: ["method": "cloud.environment.create", "params": ["environment": ["name": "cmux"]]])
        #expect(await model.respond(to: request)["ok"] as? Bool == false)
        #expect(actions.isEmpty)
        model.transport.gestures.record(click: true)
        #expect(await model.respond(to: request)["ok"] as? Bool == true)
        #expect(actions == ["create"])
    }

    /// Make default for this project writes the project's default only on the person's click; reading it does not.
    @Test func setDefaultForwardsOnlyWithAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var actions: [String] = []
        model.onCloudEnvironment = { request in actions.append(request.action); return AgentPaneReply.success([:]) }
        let read = AgentPaneRequest(body: ["method": "cloud.environment.default", "params": ["repo": "octocat/hello-world"]])
        #expect(await model.respond(to: read)["ok"] as? Bool == true)
        let write = AgentPaneRequest(body: ["method": "cloud.environment.setDefault", "params": ["repo": "octocat/hello-world", "environment": "env_a"]])
        #expect(await model.respond(to: write)["ok"] as? Bool == false)
        model.transport.gestures.record(click: true)
        #expect(await model.respond(to: write)["ok"] as? Bool == true)
        #expect(actions == ["default", "setDefault"])
    }

    @Test func readMethodsForwardWithoutSpendingAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var actions: [String] = []
        model.onCloudEnvironment = { request in actions.append(request.action); return AgentPaneReply.success([]) }
        for method in ["cloud.environment.list", "cloud.environment.get", "cloud.environment.derive"] {
            #expect(AgentPageOps.methods[method] == method)
            _ = await model.respond(to: AgentPaneRequest(body: ["method": method, "params": [:]]))
        }
        #expect(actions == ["list", "get", "derive"])
        #expect(!model.userTouched)
    }

    @Test func theCloudStartKeepsTheSelectedEnvironment() throws {
        let selected = try #require(AgentPaneCloudStart(params: ["task": "Build", "key": UUID().uuidString, "environment": "env_work"]))
        #expect(selected.environment == "env_work")
        let defaultEnvironment = try #require(AgentPaneCloudStart(params: ["task": "Build", "key": UUID().uuidString]))
        #expect(defaultEnvironment.environment == nil)
        #expect(AgentPaneCloudStart(params: ["task": "Build", "key": UUID().uuidString, "environment": 42]) == nil)
    }
}
