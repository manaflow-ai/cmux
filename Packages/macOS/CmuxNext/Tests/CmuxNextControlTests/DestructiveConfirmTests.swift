import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Destructive actions over the socket: `action.run` without
/// `confirm: true` fails with the typed `confirmation_required` error and
/// never runs the handler; with it the action runs. `action.list` marks
/// them `destructive`.
@MainActor
@Suite struct DestructiveConfirmTests {
    func router(for registry: ActionRegistry) -> ControlRouter {
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        return router
    }

    @Test func runWithoutConfirmIsATypedRefusal() async throws {
        let registry = ActionRegistry.standard()
        var ran = 0
        registry.bind("cloudKillMachine", invoke: { _ in ran += 1 })
        let router = router(for: registry)

        let refused = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "cloud kill-machine", "target": "machine:vm-1",
        ]))
        guard case .failure(let error) = refused else {
            Issue.record("expected confirmation_required")
            return
        }
        #expect(error.code == "confirmation_required")
        #expect(error.message.contains("--confirm"))
        #expect(error.data?["action"] == "cloudKillMachine")
        #expect(ran == 0)

        let result = try await router.handle(ControlRequest(id: "2", method: "action.run", params: [
            "action": "cloud kill-machine", "target": "machine:vm-1", "args": ["confirm": true],
        ])).get()
        #expect(result["ran"] == true)
        #expect(ran == 1)
    }

    @Test func bridgeRefusesUnconfirmedDestructiveRuns() {
        let registry = ActionRegistry.standard()
        var ran = 0
        registry.bind("workspaceGroup.delete", invoke: { _ in ran += 1 })
        let bridge = RegistryControlBridge(registry: registry)
        #expect(bridge.performAction(ControlActionRequest(actionID: "workspaceGroup.delete")) == .confirmationRequired)
        #expect(bridge.performAction(ControlActionRequest(actionID: "workspaceGroup.delete", arguments: ["confirm": .bool(true)])) == .ran)
        #expect(ran == 1)
    }

    @Test func listMarksDestructiveActions() async throws {
        let registry = ActionRegistry.standard()
        let list = try await router(for: registry).handle(ControlRequest(id: "1", method: "action.list", params: [:])).get()
        let actions = try #require(list["actions"]?.arrayValue)
        #expect(actions.first { $0["id"] == "tabGroup.close" }?["destructive"] == true)
        #expect(actions.first { $0["id"] == "tabGroup.rename" }?["destructive"] == false)
    }
}
