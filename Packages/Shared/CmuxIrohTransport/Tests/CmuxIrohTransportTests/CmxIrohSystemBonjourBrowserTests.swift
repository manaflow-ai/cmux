import Foundation
import Testing
import dnssd
@testable import CmuxIrohTransport

@Suite
struct CmxIrohSystemBonjourBrowserTests {
    @Test
    func hostileBrowseFloodIsBoundedAndAliasesAreValidatedBeforeResolve() async throws {
        let dnsService = TestBonjourDNSService()
        let clock = TestBonjourClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let browser = CmxIrohSystemBonjourBrowser(
            dnsService: dnsService,
            clock: clock,
            maximumPendingResolves: 2,
            resolveTimeout: 5
        )
        let stream = await browser.events()
        let observationTask = Task {
            for await _ in stream {}
        }

        for alias in [
            "short",
            String(repeating: "A", count: 32),
            String(repeating: "g", count: 32),
            String(repeating: "0", count: 31) + "-",
        ] {
            await dnsService.emitAdded(serviceName: alias)
        }
        for alias in canonicalAliases(count: 20) {
            await dnsService.emitAdded(serviceName: alias)
        }
        await dnsService.waitForResolveStartCount(2)

        let snapshot = dnsService.snapshot()
        #expect(snapshot.resolveStarts.count == 2)
        #expect(snapshot.maximumActiveResolveCount == 2)
        #expect(snapshot.resolveStarts.allSatisfy(
            CmxIrohLANRendezvousAliasGenerator.isCanonicalAlias
        ))

        await browser.stop()
        await observationTask.value
    }

    @Test
    func unresolvedOperationExpiresAndFreesCapacityForAnotherAlias() async throws {
        let dnsService = TestBonjourDNSService()
        let clock = TestBonjourClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let browser = CmxIrohSystemBonjourBrowser(
            dnsService: dnsService,
            clock: clock,
            maximumPendingResolves: 1,
            resolveTimeout: 5
        )
        let stream = await browser.events()
        let observationTask = Task {
            for await _ in stream {}
        }
        let aliases = canonicalAliases(count: 2)

        await dnsService.emitAdded(serviceName: aliases[0])
        await clock.waitForPendingSleepCount(1)

        await clock.advance(by: 5)
        await dnsService.waitForResolveCancellationCount(1)
        #expect(await clock.pendingSleepCount() == 0)

        await dnsService.emitAdded(serviceName: aliases[1])
        await dnsService.waitForResolveStartCount(2)
        let snapshot = dnsService.snapshot()
        #expect(snapshot.resolveStarts == aliases)
        #expect(snapshot.activeResolveCount == 1)
        #expect(snapshot.maximumActiveResolveCount == 1)

        await browser.stop()
        await observationTask.value
    }

    @Test
    func queuedServiceStartsWhenActiveResolveCompletes() async throws {
        let dnsService = TestBonjourDNSService()
        let clock = TestBonjourClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let browser = CmxIrohSystemBonjourBrowser(
            dnsService: dnsService,
            clock: clock,
            maximumPendingResolves: 1,
            resolveTimeout: 5
        )
        let stream = await browser.events()
        let observationTask = Task {
            for await _ in stream {}
        }
        let aliases = canonicalAliases(count: 2)

        await dnsService.emitAdded(serviceName: aliases[0])
        await dnsService.emitAdded(serviceName: aliases[1])
        await dnsService.waitForResolveStartCount(1)
        #expect(dnsService.snapshot().resolveStarts == [aliases[0]])

        await dnsService.emitResolved(serviceName: aliases[0])
        await dnsService.waitForResolveStartCount(2)

        #expect(dnsService.snapshot().resolveStarts == aliases)
        #expect(dnsService.snapshot().maximumActiveResolveCount == 1)

        await browser.stop()
        await observationTask.value
    }

    @Test
    func canonicalServiceStillResolvesAfterGarbageBrowseEvents() async throws {
        let dnsService = TestBonjourDNSService()
        let clock = TestBonjourClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let browser = CmxIrohSystemBonjourBrowser(
            dnsService: dnsService,
            clock: clock,
            maximumPendingResolves: 1,
            resolveTimeout: 5
        )
        let stream = await browser.events()
        var iterator = stream.makeAsyncIterator()

        for index in 0 ..< 100 {
            await dnsService.emitAdded(serviceName: "hostile-\(index)")
        }
        let alias = String(repeating: "a", count: 32)
        await dnsService.emitAdded(serviceName: alias)
        await clock.waitForPendingSleepCount(1)
        await dnsService.emitResolved(serviceName: alias)

        guard case let .resolved(id, service) = await iterator.next() else {
            Issue.record("Expected the canonical service to resolve")
            await browser.stop()
            return
        }
        #expect(id.serviceName == alias)
        #expect(service.serviceName == alias)
        #expect(dnsService.snapshot().resolveStarts == [alias])
        await clock.waitUntilIdle()
        #expect(await clock.pendingSleepCount() == 0)

        await browser.stop()
    }

    @Test
    func stopCancelsBrowseResolvesAndEveryDeadline() async throws {
        let dnsService = TestBonjourDNSService()
        let clock = TestBonjourClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let browser = CmxIrohSystemBonjourBrowser(
            dnsService: dnsService,
            clock: clock,
            maximumPendingResolves: 3,
            resolveTimeout: 5
        )
        let stream = await browser.events()
        let aliases = canonicalAliases(count: 3)
        for alias in aliases {
            await dnsService.emitAdded(serviceName: alias)
        }
        await clock.waitForPendingSleepCount(3)

        await browser.stop()
        await dnsService.waitForResolveCancellationCount(3)
        await clock.waitUntilIdle()

        let snapshot = dnsService.snapshot()
        #expect(snapshot.browseCancellationCount == 1)
        #expect(snapshot.resolveCancellationCount == 3)
        #expect(snapshot.activeResolveCount == 0)
        #expect(await clock.pendingSleepCount() == 0)

        await dnsService.emitAdded(serviceName: String(repeating: "f", count: 32))
        #expect(dnsService.snapshot().resolveStarts == aliases)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test
    func cancellingLastObservationCancelsBrowseResolveAndDeadline() async throws {
        let dnsService = TestBonjourDNSService()
        let clock = TestBonjourClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let browser = CmxIrohSystemBonjourBrowser(
            dnsService: dnsService,
            clock: clock,
            maximumPendingResolves: 1,
            resolveTimeout: 5
        )
        let stream = await browser.events()
        let observationTask = Task {
            for await _ in stream {}
        }
        await dnsService.emitAdded(serviceName: String(repeating: "a", count: 32))
        await clock.waitForPendingSleepCount(1)

        observationTask.cancel()
        await observationTask.value
        await dnsService.waitForResolveCancellationCount(1)
        await clock.waitUntilIdle()

        let snapshot = dnsService.snapshot()
        #expect(snapshot.browseCancellationCount == 1)
        #expect(snapshot.resolveCancellationCount == 1)
        #expect(snapshot.activeResolveCount == 0)
        #expect(await clock.pendingSleepCount() == 0)
    }

    @Test
    func cancellingClockWaitReleasesItsContinuation() async {
        let clock = TestBonjourClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let waiter = Task {
            await clock.waitForPendingSleepCount(1)
        }

        waiter.cancel()
        await waiter.value

        #expect(await clock.pendingSleepCount() == 0)
    }

    private func canonicalAliases(count: Int) -> [String] {
        (0 ..< count).map { index in
            String(repeating: "0", count: 24) + String(format: "%08x", index)
        }
    }
}
