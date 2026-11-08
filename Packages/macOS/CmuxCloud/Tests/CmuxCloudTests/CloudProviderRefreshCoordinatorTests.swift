@testable import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

@MainActor
struct CloudProviderRefreshCoordinatorTests {
    @Test("Panel refreshes coalesce per machine while separate machines remain independent")
    func panelRefreshesCoalescePerMachine() async {
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        var machines: [SurfaceMachineID] = []
        let coordinator = CloudMachineRefreshCoordinator { machine in
            machines.append(machine)
            if machines.count == 2 { started.resolve(true) }
            _ = await release.result
        }
        coordinator.refresh(.cloud("first"))
        coordinator.refresh(.cloud("first"))
        coordinator.refresh(.cloud("second"))
        _ = await started.result
        #expect(machines.count == 2)
        #expect(Set(machines) == [.cloud("first"), .cloud("second")])
        coordinator.cancelAll()
        release.resolve(true)
    }

    @Test("Canceled panel refreshes do not start their operation")
    func canceledRefreshDoesNotStart() async {
        var calls = 0
        let coordinator = CloudMachineRefreshCoordinator { _ in calls += 1 }
        coordinator.refresh(.cloud("canceled"))
        coordinator.cancelAll()
        await Task.yield()
        #expect(calls == 0)
    }

    @Test("Concurrent catalog reads cannot supersede the initial graph publication")
    func concurrentReadersShareTheFirstPublication() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let joining = CloudLinkFirstValue<Bool>()
        var generation = 0
        let operation: @MainActor (Bool) async -> Bool = { _ in
            generation += 1
            let mine = generation
            started.resolve(true)
            _ = await release.result
            return mine == generation
        }
        let first = Task { await coordinator.refresh(force: false, operation: operation) }
        _ = await started.result
        let second = Task {
            joining.resolve(true)
            return await coordinator.refresh(force: false, operation: operation)
        }
        _ = await joining.result
        #expect(generation == 1)
        release.resolve(true)
        #expect(await first.value)
        #expect(await second.value)
    }

    @Test("Forced reads queued during a snapshot share one later forced pass")
    func forcedReadersWaitForAReadStartedAfterTheirRequest() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let firstWaiting = CloudLinkFirstValue<Bool>()
        let secondWaiting = CloudLinkFirstValue<Bool>()
        var forces: [Bool] = []
        let operation: @MainActor (Bool) async -> Bool = { force in
            forces.append(force)
            started.resolve(true)
            _ = await release.result
            return true
        }
        let background = Task { await coordinator.refresh(force: false, operation: operation) }
        _ = await started.result
        let first = Task {
            firstWaiting.resolve(true)
            return await coordinator.refresh(force: true, operation: operation)
        }
        _ = await firstWaiting.result
        let second = Task {
            secondWaiting.resolve(true)
            return await coordinator.refresh(force: true, operation: operation)
        }
        _ = await secondWaiting.result
        #expect(forces == [false])
        release.resolve(true)
        #expect(await background.value)
        #expect(await first.value)
        #expect(await second.value)
        #expect(forces == [false, true])
    }

    @Test("Forced readers that resume after the trailing pass share its result")
    func forcedReadersDoNotOpenDuplicateTrailingPasses() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let initialStarted = CloudLinkFirstValue<Bool>()
        let releaseInitial = CloudLinkFirstValue<Bool>()
        var calls = 0
        let operation: @MainActor (Bool) async -> Bool = { force in
            calls += 1
            if !force {
                initialStarted.resolve(true)
                _ = await releaseInitial.result
            }
            return true
        }

        let initial = Task { await coordinator.refresh(force: false, operation: operation) }
        _ = await initialStarted.result
        // Both forced callers are already waiting on the same old pass. The
        // first continuation owns the trailing pass; the second must consume
        // that result even if it resumes after the owner cleared inFlight.
        let first = Task { await coordinator.refresh(force: true, operation: operation) }
        let second = Task { await coordinator.refresh(force: true, operation: operation) }
        releaseInitial.resolve(true)

        #expect(await initial.value)
        #expect(await first.value)
        #expect(await second.value)
        #expect(calls == 2)
    }

    @Test("Invalidation cannot be undone by a waiter that resumes late")
    func invalidationDoesNotAllowStaleForcedPublication() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let operationReturned = CloudLinkFirstValue<Bool>()
        let allowOperationToReturn = CloudLinkFirstValue<Bool>()
        let secondEntered = CloudLinkFirstValue<Bool>()
        var calls = 0
        let operation: @MainActor (Bool) async -> Bool = { _ in
            calls += 1
            if calls == 1 {
                started.resolve(true)
                _ = await release.result
                // Hold the pass owner after its I/O has completed. The test
                // can now invalidate at a known point before the owner
                // publishes or resumes any waiter.
                operationReturned.resolve(true)
                _ = await allowOperationToReturn.result
                return false
            }
            return true
        }

        let first = Task { await coordinator.refresh(force: true, operation: operation) }
        _ = await started.result
        let second = Task {
            // Admit the second waiter before releasing the first operation so
            // both continuations participate in the invalidation boundary.
            secondEntered.resolve(true)
            return await coordinator.refresh(force: true, operation: operation)
        }
        _ = await secondEntered.result
        release.resolve(true)
        _ = await operationReturned.result
        // Invalidate while the pass owner is held after the operation has
        // completed. A stale result must not be published or reused.
        coordinator.invalidate()
        allowOperationToReturn.resolve(true)
        #expect(await first.value)
        #expect(await second.value)
        // The second request arrived while the original entry was in flight,
        // so it correctly receives one trailing forced pass of its own after
        // the owner repairs the invalidated pass.
        #expect(calls == 3)

        // The invalidation forced a new operation. Invalidate once more so
        // this read cannot reuse the current completion either.
        coordinator.invalidate()
        #expect(await coordinator.refresh(force: true, operation: operation))
        #expect(calls == 4)
    }

    @Test("A metadata change restarts an invalidated pass before releasing its readers")
    func invalidatedPassFinishesWithTheCurrentGraph() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        var calls = 0
        let read = Task {
            await coordinator.refresh(force: true) { _ in
                calls += 1
                if calls == 1 {
                    started.resolve(true)
                    _ = await release.result
                    return false
                }
                return true
            }
        }
        _ = await started.result
        coordinator.invalidate()
        release.resolve(true)
        #expect(await read.value)
        #expect(calls == 2)
    }

    @Test("Retiring a provider cancels its current pass and queued forced readers")
    func cancellationRetiresQueuedRequests() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let waiting = CloudLinkFirstValue<Bool>()
        var calls = 0
        let operation: @MainActor (Bool) async -> Bool = { _ in
            calls += 1
            started.resolve(true)
            _ = await release.result
            return true
        }
        let first = Task { await coordinator.refresh(force: false, operation: operation) }
        _ = await started.result
        let forced = Task {
            waiting.resolve(true)
            return await coordinator.refresh(force: true, operation: operation)
        }
        _ = await waiting.result
        coordinator.cancel()
        release.resolve(true)
        #expect(await first.value == false)
        #expect(await forced.value == false)
        #expect(calls == 1)
    }
}
