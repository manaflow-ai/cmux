import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// The Chief host's real entrypoint (optchat-chief workspaces.rs `open_request_for`): its exact
/// `action.run` request goes through the control router and the action catalog's argument
/// validation to the handler. Live proof subp7 found the catalog refusing `host` while the
/// store-level tests passed; this test covers that layer.
@MainActor
@Suite struct ChiefSubagentWorkspaceRunTests {
    @Test func theChiefHostsOpenRequestReachesTheHandlerWithItsHost() async throws {
        let registry = ActionRegistry.standard()
        var seen: ActionInvocation?
        registry.bind("agent.openSessionWorkspace", invoke: { seen = $0 })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil, configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        let key = "0f3c2a9e-1b7d-4e5f-9a1b-2c3d4e5f6a7b"
        // Byte for byte the params of optchat-chief's request.
        let json = #"{"action":"agent.openSessionWorkspace","args":{"session":"s1","name":"a1 · count lines","key":"\#(key)","cwd":"/tmp","host":"chief:0a1b2c3d"},"wait":true,"origin":"script","idempotency_key":"optchat-subagent-workspace-\#(key)"}"#
        guard case .object(let params)? = JSONValue(foundation: try JSONSerialization.jsonObject(with: Data(json.utf8))) else {
            Issue.record("the request is not a JSON object")
            return
        }
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: params))
        if case .failure(let error) = result { Issue.record("refused: \(error.code) \(error.message)") }
        #expect(seen?["host"]?.stringValue == "chief:0a1b2c3d")
        #expect(seen?["session"]?.stringValue == "s1")
    }
}
