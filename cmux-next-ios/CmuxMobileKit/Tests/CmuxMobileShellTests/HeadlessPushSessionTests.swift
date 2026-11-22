import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct HeadlessPushSessionTests {
    @MainActor final class Coordinator {
        var stops = 0
    }

    /// A one-shot barrier: no sleeps or scheduler-dependent yield counts.
    @MainActor final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    @Test(arguments: [false, true])
    func overlappingRepliesShareCreationAndStopAfterTheLastDelivery(cancelFirst: Bool) async {
        let session = HeadlessPushSession<Coordinator>()
        let creating = Gate(), releaseCreation = Gate(), secondStarted = Gate(), bothDelivering = Gate()
        let releaseFirst = Gate(), releaseSecond = Gate()
        var made: [Coordinator] = []
        var used: [Coordinator] = []
        let create: @MainActor () async -> Coordinator? = {
            let coordinator = Coordinator()
            made.append(coordinator)
            creating.open()
            await releaseCreation.wait()
            return coordinator
        }
        let stop: @MainActor (Coordinator) -> Void = { $0.stops += 1 }
        let first = Task { @MainActor in
            await session.withCoordinator(create: create, stop: stop) { coordinator in
                if let coordinator { used.append(coordinator) }
                if used.count == 2 { bothDelivering.open() }
                await releaseFirst.wait()
            }
        }
        await creating.wait()
        #expect(session.running)
        let second = Task { @MainActor in
            secondStarted.open()
            // This actor turn reaches withCoordinator's suspension before the
            // test can resume and release the first factory call.
            await session.withCoordinator(create: create, stop: stop) { coordinator in
                if let coordinator { used.append(coordinator) }
                if used.count == 2 { bothDelivering.open() }
                await releaseSecond.wait()
            }
        }
        await secondStarted.wait()
        if cancelFirst { first.cancel() }
        releaseCreation.open()
        await bothDelivering.wait()
        #expect(made.count == 1)
        #expect(used.first === used.last)
        releaseFirst.open()
        await first.value
        #expect(session.running)
        #expect(made.allSatisfy { $0.stops == 0 })

        // A reply joining after initialization also reuses the live coordinator.
        await session.withCoordinator(create: create, stop: stop) { coordinator in
            #expect(coordinator === used.first)
        }
        #expect(made.count == 1)
        releaseSecond.open()
        await second.value
        #expect(!session.running)
        #expect(made.allSatisfy { $0.stops == 1 })

        // A subsequent cold batch must not reuse the stopped coordinator.
        await session.withCoordinator(create: create, stop: stop) { coordinator in
            #expect(coordinator !== used.first)
        }
        #expect(made.count == 2)
        #expect(made.allSatisfy { $0.stops == 1 })
        #expect(!session.running)
    }

    @Test func failedCreationIsSharedAndTheNextBatchCanRetry() async {
        let session = HeadlessPushSession<Coordinator>()
        let creating = Gate(), releaseCreation = Gate(), secondStarted = Gate(), bothDelivering = Gate()
        let releaseDeliveries = Gate()
        var attempts = 0
        var deliveries = 0
        let create: @MainActor () async -> Coordinator? = {
            attempts += 1
            creating.open()
            await releaseCreation.wait()
            return nil
        }
        let deliver: @MainActor (Coordinator?) async -> Void = { coordinator in
            #expect(coordinator == nil)
            deliveries += 1
            if deliveries == 2 { bothDelivering.open() }
            await releaseDeliveries.wait()
        }
        let stop: @MainActor (Coordinator) -> Void = { _ in Issue.record("A failed factory has nothing to stop") }
        let first = Task { @MainActor in
            await session.withCoordinator(create: create, stop: stop, deliver: deliver)
        }
        await creating.wait()
        let second = Task { @MainActor in
            secondStarted.open()
            await session.withCoordinator(create: create, stop: stop, deliver: deliver)
        }
        await secondStarted.wait()
        releaseCreation.open()
        await bothDelivering.wait()
        #expect(attempts == 1)
        #expect(session.running)
        // A completed nil result stays shared until this batch has drained.
        await session.withCoordinator(create: create, stop: stop) { coordinator in
            #expect(coordinator == nil)
        }
        #expect(attempts == 1)
        releaseDeliveries.open()
        await first.value
        await second.value
        #expect(!session.running)
        let recovered = Coordinator()
        await session.withCoordinator(create: { recovered }, stop: { $0.stops += 1 }) { coordinator in
            #expect(coordinator === recovered)
        }
        #expect(recovered.stops == 1)
        #expect(!session.running)
    }
}
