import Foundation
import Testing
@testable import CmuxCloudMachines

@MainActor
struct CloudWorkspaceCoordinatorTests {
    @Test func createsOnCapturedMachine() async throws {
        var createdMachine: String?
        let coordinator = CloudWorkspaceCoordinator(
            allowsOperation: { true },
            loadMachines: { [CloudMachineDescriptor(id: "machine-a", isDesktop: true)] },
            createWorkspace: { id, focus in
                #expect(focus)
                createdMachine = id
                return UUID()
            }
        )

        _ = try await coordinator.createOnMachine(machineID: "machine-a", focus: true)
        #expect(createdMachine == "machine-a")
    }

    @Test func unavailableCapturedMachineFailsClosed() async {
        let coordinator = CloudWorkspaceCoordinator(
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

    @Test func concurrentCreatesCoalescePerMachine() async throws {
        let started = AsyncStream<Void>.makeStream()
        var releaseA: CheckedContinuation<Void, Never>?
        var targets: [String] = []
        let coordinator = CloudWorkspaceCoordinator(
            allowsOperation: { true },
            loadMachines: { [CloudMachineDescriptor(id: "machine-a", isDesktop: true), CloudMachineDescriptor(id: "machine-b", isDesktop: false)] },
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
        let first = Task { try await coordinator.createOnMachine(machineID: "machine-a", focus: true) }
        for await _ in started.stream { break }
        #expect(try await coordinator.createOnMachine(machineID: "machine-a", focus: true) == nil)
        #expect(try await coordinator.createOnMachine(machineID: "machine-b", focus: true) != nil)
        releaseA?.resume()
        _ = try await first.value
        #expect(targets == ["machine-a", "machine-b"])
    }
}
