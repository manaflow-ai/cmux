import Testing
@testable import CmuxBrowser

@Suite("Browser page metadata DNS resolver")
struct BrowserPageMetadataDNSResolverTests {
    @Test(.timeLimit(.minutes(1)))
    func saturatedRequestsWaitForWorkerCapacity() async throws {
        let worker = ControllablePageMetadataDNSWorker()
        let resolver = BrowserPageMetadataDNSResolver(
            worker: worker,
            maximumConcurrentQueries: 1,
            maximumPendingQueries: 2
        )
        let firstAddress = BrowserPageMetadataResolvedAddress(
            family: .ipv4,
            bytes: [1, 1, 1, 1]
        )
        let secondAddress = BrowserPageMetadataResolvedAddress(
            family: .ipv4,
            bytes: [8, 8, 8, 8]
        )

        let firstTask = Task { await resolver.addresses(for: "first.example") }
        #expect(await worker.waitForStartedQueryCount(1) == ["first.example"])
        let secondTask = Task { await resolver.addresses(for: "second.example") }
        while await resolver.pendingQueryCount == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }

        await worker.complete(host: "first.example", addresses: [firstAddress])
        #expect(await worker.waitForStartedQueryCount(2) == ["first.example", "second.example"])
        await worker.complete(host: "second.example", addresses: [secondAddress])

        #expect(await firstTask.value == [firstAddress])
        #expect(await secondTask.value == [secondAddress])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelingPendingRequestRemovesItFromQueue() async throws {
        let worker = ControllablePageMetadataDNSWorker()
        let resolver = BrowserPageMetadataDNSResolver(
            worker: worker,
            maximumConcurrentQueries: 1,
            maximumPendingQueries: 2
        )
        let address = BrowserPageMetadataResolvedAddress(
            family: .ipv4,
            bytes: [1, 1, 1, 1]
        )

        let runningTask = Task { await resolver.addresses(for: "running.example") }
        #expect(await worker.waitForStartedQueryCount(1) == ["running.example"])
        let pendingTask = Task { await resolver.addresses(for: "pending.example") }
        while await resolver.pendingQueryCount == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }

        pendingTask.cancel()
        #expect(await pendingTask.value.isEmpty)
        #expect(await resolver.pendingQueryCount == 0)
        await worker.complete(host: "running.example", addresses: [address])

        #expect(await runningTask.value == [address])
        #expect(await worker.recordedStartedHosts() == ["running.example"])
    }

    @Test(.timeLimit(.minutes(1)))
    func canceledRunningRequestKeepsSlotUntilWorkerCompletes() async throws {
        let worker = ControllablePageMetadataDNSWorker()
        let resolver = BrowserPageMetadataDNSResolver(
            worker: worker,
            maximumConcurrentQueries: 1,
            maximumPendingQueries: 2
        )
        let address = BrowserPageMetadataResolvedAddress(
            family: .ipv4,
            bytes: [8, 8, 4, 4]
        )

        let canceledTask = Task { await resolver.addresses(for: "blocked.example") }
        #expect(await worker.waitForStartedQueryCount(1) == ["blocked.example"])
        canceledTask.cancel()
        #expect(await canceledTask.value.isEmpty)

        let waitingTask = Task { await resolver.addresses(for: "waiting.example") }
        while await resolver.pendingQueryCount == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        #expect(await worker.recordedStartedHosts() == ["blocked.example"])

        await worker.complete(host: "blocked.example", addresses: [address])
        #expect(await worker.waitForStartedQueryCount(2) == ["blocked.example", "waiting.example"])
        await worker.complete(host: "waiting.example", addresses: [address])
        #expect(await waitingTask.value == [address])
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingQueueRejectsOnlyAfterItsBound() async throws {
        let worker = ControllablePageMetadataDNSWorker()
        let resolver = BrowserPageMetadataDNSResolver(
            worker: worker,
            maximumConcurrentQueries: 1,
            maximumPendingQueries: 1
        )

        let runningTask = Task { await resolver.addresses(for: "running.example") }
        #expect(await worker.waitForStartedQueryCount(1) == ["running.example"])
        let pendingTask = Task { await resolver.addresses(for: "pending.example") }
        while await resolver.pendingQueryCount == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }

        #expect(await resolver.addresses(for: "overflow.example").isEmpty)
        pendingTask.cancel()
        _ = await pendingTask.value
        runningTask.cancel()
        _ = await runningTask.value
        await worker.complete(host: "running.example", addresses: [])
    }
}
