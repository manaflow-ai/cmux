import Foundation
import Testing
@testable import CmuxCloudMachines

@MainActor
struct DefaultCloudMachineStoreTests {
    @Test func selectionUsesDesktopThenIdentityAndPersists() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DefaultCloudMachineStore(defaults: defaults)
        let machines = [
            CloudMachineDescriptor(id: "0", isDesktop: false),
            CloudMachineDescriptor(id: "b", isDesktop: true),
            CloudMachineDescriptor(id: "a", isDesktop: true)
        ]
        #expect(DefaultCloudMachineStore.chooseMachine(machines)?.id == "a")
        store.machineID = "b"
        #expect(store.resolveMachineID(from: machines, isComplete: true) == "b")
        store.machineID = "deleted"
        #expect(store.resolveMachineID(from: machines, isComplete: true) == "a")
        #expect(DefaultCloudMachineStore(defaults: defaults).machineID == "a")
    }

    @Test(arguments: [false, true]) func emptyCatalogPreservesDefault(isComplete: Bool) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = DefaultCloudMachineStore(defaults: defaults)
        store.machineID = "starred"
        #expect(store.resolveMachineID(from: [], isComplete: isComplete) == nil)
        #expect(store.machineID == "starred")
        store.machineID = nil
    }

    @Test func partialCatalogCannotSelectOrReplaceDefault() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = DefaultCloudMachineStore(defaults: defaults)
        let partial = [CloudMachineDescriptor(id: "other", isDesktop: true)]
        #expect(store.resolveMachineID(from: partial) == nil)
        #expect(store.machineID == nil)
        store.machineID = "starred"
        #expect(store.resolveMachineID(from: partial) == nil)
        #expect(store.machineID == "starred")
        #expect(store.resolveMachineID(from: [CloudMachineDescriptor(id: "starred", isDesktop: false)]) == "starred")
        store.machineID = nil
    }
}
