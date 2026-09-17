import Foundation
import Testing
@testable import CmuxCloudMachines

@MainActor
struct CloudWorkspaceCoordinatorTests {
    @Test func loadsFreshFleetAndReturnsExactCreationReceipt() async throws {
        let store = DefaultCloudMachineStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { store.machineID = nil }
        store.machineID = "starred"
        let receipt = UUID()
        var loads = 0
        var targets: [String] = []
        let coordinator = CloudWorkspaceCoordinator(
            defaultMachineStore: store,
            allowsOperation: { true },
            loadMachines: {
                loads += 1
                return [CloudMachineDescriptor(id: "other", isDesktop: true), CloudMachineDescriptor(id: "starred", isDesktop: false)]
            },
            createWorkspace: { id, focus in
                #expect(focus)
                targets.append(id)
                return receipt
            }
        )
        #expect(try await coordinator.createOnDefaultMachine(focus: true) == receipt)
        #expect(try await coordinator.createOnDefaultMachine(focus: true) == receipt)
        #expect(loads == 2)
        #expect(targets == ["starred", "starred"])
    }

    @Test(arguments: [false, true]) func unavailableActionsDoNotCreate(accessEndsDuringList: Bool) async throws {
        let store = DefaultCloudMachineStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var available = accessEndsDuringList
        var loads = 0
        var creates = 0
        let coordinator = CloudWorkspaceCoordinator(
            defaultMachineStore: store,
            allowsOperation: { available },
            loadMachines: {
                loads += 1
                available = false
                return [CloudMachineDescriptor(id: "machine", isDesktop: true)]
            },
            createWorkspace: { _, _ in creates += 1; return UUID() }
        )
        #expect(try await coordinator.createOnDefaultMachine(focus: false) == nil)
        #expect(loads == (accessEndsDuringList ? 1 : 0))
        #expect(creates == 0)
        #expect(store.machineID == nil)
    }

    @Test func failedListPreservesDefaultAndDoesNotCreate() async {
        let store = DefaultCloudMachineStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { store.machineID = nil }
        store.machineID = "starred"
        let coordinator = CloudWorkspaceCoordinator(
            defaultMachineStore: store,
            allowsOperation: { true },
            loadMachines: { throw CancellationError() },
            createWorkspace: { _, _ in Issue.record("Must not create after a failed list"); return nil }
        )
        await #expect(throws: CancellationError.self) { try await coordinator.createOnDefaultMachine(focus: false) }
        #expect(store.machineID == "starred")
    }
}
