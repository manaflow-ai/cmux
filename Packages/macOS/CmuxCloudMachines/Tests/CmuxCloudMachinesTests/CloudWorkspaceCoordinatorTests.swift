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

    @Test func createsOnCapturedMachineInsteadOfChangingDefault() async throws {
        let store = DefaultCloudMachineStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.machineID = "machine-a"
        var createdMachine: String?
        let coordinator = CloudWorkspaceCoordinator(
            defaultMachineStore: store,
            allowsOperation: { true },
            loadMachines: {
                store.machineID = "machine-b"
                return [
                    CloudMachineDescriptor(id: "machine-a", isDesktop: true),
                    CloudMachineDescriptor(id: "machine-b", isDesktop: true)
                ]
            },
            createWorkspace: { id, _ in
                createdMachine = id
                return UUID()
            }
        )

        _ = try await coordinator.createOnMachine(machineID: "machine-a", focus: true)
        #expect(createdMachine == "machine-a")
        #expect(store.machineID == "machine-b")
    }

    @Test func unavailableCapturedMachineFailsClosed() async {
        let coordinator = CloudWorkspaceCoordinator(
            defaultMachineStore: DefaultCloudMachineStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            allowsOperation: { true },
            loadMachines: { [CloudMachineDescriptor(id: "machine-b", isDesktop: true)] },
            createWorkspace: { _, _ in
                Issue.record("Must not create for an unavailable captured machine")
                return UUID()
            }
        )

        await #expect(throws: CloudWorkspaceCoordinatorError.machineUnavailable("machine-a")) {
            try await coordinator.createOnMachine(machineID: "machine-a", focus: false)
        }
    }

    @Test func defaultAndSelectedCommandsCoalesceOnlyTheSameMachine() async throws {
        let store = DefaultCloudMachineStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.machineID = "machine-a"
        let started = AsyncStream<Void>.makeStream()
        var releaseA: CheckedContinuation<Void, Never>?
        var targets: [String] = []
        let coordinator = CloudWorkspaceCoordinator(
            defaultMachineStore: store,
            allowsOperation: { true },
            loadMachines: {
                [CloudMachineDescriptor(id: "machine-a", isDesktop: true), CloudMachineDescriptor(id: "machine-b", isDesktop: false)]
            },
            createWorkspace: { id, _ in
                targets.append(id)
                if id == "machine-a" {
                    await withCheckedContinuation { continuation in
                        releaseA = continuation
                        started.continuation.yield(())
                    }
                }
                return UUID()
            }
        )
        let first = Task { try await coordinator.createOnDefaultMachine(focus: true) }
        for await _ in started.stream { break }
        #expect(try await coordinator.createOnMachine(machineID: "machine-a", focus: true) == nil)
        #expect(try await coordinator.createOnMachine(machineID: "machine-b", focus: true) != nil)
        releaseA?.resume()
        _ = try await first.value
        #expect(targets == ["machine-a", "machine-b"])
    }
}
