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
