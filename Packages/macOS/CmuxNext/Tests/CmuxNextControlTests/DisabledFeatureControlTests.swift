import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// A turned-off feature's actions answer `feature.disabled` on the socket
/// and the CLI, and `action.list` does not offer them.
@MainActor
@Suite struct DisabledFeatureControlTests {
    @Test func aDisabledFeatureIsRefusedAndUnlisted() async throws {
        let registry = ActionRegistry.standard()
        var ran = false
        registry.bind("newCloudMachine") { ran = true }
        registry.disabledFeatures = [.cloud]
        let router = ControlRouter(identity: testIdentity(), executor: RegistryControlBridge(registry: registry), settings: nil)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))

        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "newCloudMachine"]))
        guard case .failure(let error) = result else {
            Issue.record("a disabled feature ran")
            return
        }
        #expect(error.code == "feature.disabled")
        #expect(error.data?["feature"] == "cloud")
        #expect(!ran)

        let list = try await router.handle(ControlRequest(id: "2", method: "action.list", params: [:])).get()
        let ids = list["actions"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(!ids.contains("newCloudMachine"))
        #expect(ids.contains("splitRight"))
    }
}
