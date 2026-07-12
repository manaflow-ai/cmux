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
        #expect(dnsService.snapshot().resolveStarts == [aliases[0]])

        await dnsService.emitResolved(serviceName: aliases[0])

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

private final class TestBonjourOperation: CmxIrohBonjourOperation, Sendable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}

private final class TestBonjourDNSService: CmxIrohBonjourDNSService, @unchecked Sendable {
    struct Snapshot: Sendable {
        let resolveStarts: [String]
        let activeResolveCount: Int
        let maximumActiveResolveCount: Int
        let resolveCancellationCount: Int
        let browseCancellationCount: Int
    }

    private struct ResolveEntry {
        let serviceName: String
        let handler: CmxIrohBonjourResolveHandler
    }

    private let lock = NSLock()
    private var browseHandler: CmxIrohBonjourBrowseHandler?
    private var browseOperationID: UUID?
    private var resolves: [UUID: ResolveEntry] = [:]
    private var resolveStarts: [String] = []
    private var maximumActiveResolveCount = 0
    private var cancelledResolveIDs: Set<UUID> = []
    private var browseCancellationCount = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func startBrowse(
        serviceType _: String,
        domain _: String,
        handler: @escaping CmxIrohBonjourBrowseHandler
    ) throws -> any CmxIrohBonjourOperation {
        let id = UUID()
        lock.withLock {
            browseHandler = handler
            browseOperationID = id
        }
        return TestBonjourOperation { [weak self] in
            self?.cancelBrowse(id: id)
        }
    }

    func startResolve(
        id: CmxIrohBonjourServiceID,
        regtype _: String,
        domain _: String,
        handler: @escaping CmxIrohBonjourResolveHandler
    ) throws -> any CmxIrohBonjourOperation {
        let operationID = UUID()
        lock.withLock {
            resolveStarts.append(id.serviceName)
            resolves[operationID] = ResolveEntry(
                serviceName: id.serviceName,
                handler: handler
            )
            maximumActiveResolveCount = max(maximumActiveResolveCount, resolves.count)
        }
        return TestBonjourOperation { [weak self] in
            self?.cancelResolve(id: operationID)
        }
    }

    func emitAdded(serviceName: String, interfaceIndex: UInt32 = 4) async {
        let handler = lock.withLock { browseHandler }
        await handler?(
            DNSServiceFlags(kDNSServiceFlagsAdd),
            interfaceIndex,
            Int32(kDNSServiceErr_NoError),
            serviceName,
            "\(CmxIrohLANAdvertisement.serviceType).",
            CmxIrohLANAdvertisement.domain
        )
    }

    func emitResolved(serviceName: String, interfaceIndex: UInt32 = 4) async {
        let handler = lock.withLock {
            resolves.values.first(where: { $0.serviceName == serviceName })?.handler
        }
        await handler?(
            Int32(kDNSServiceErr_NoError),
            interfaceIndex,
            "h-\(serviceName).local.",
            50_906,
            Data()
        )
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                resolveStarts: resolveStarts,
                activeResolveCount: resolves.count,
                maximumActiveResolveCount: maximumActiveResolveCount,
                resolveCancellationCount: cancelledResolveIDs.count,
                browseCancellationCount: browseCancellationCount
            )
        }
    }

    func waitForResolveCancellationCount(_ expectedCount: Int) async {
        while snapshot().resolveCancellationCount < expectedCount {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if cancelledResolveIDs.count >= expectedCount { return true }
                    cancellationWaiters.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
    }

    private func cancelBrowse(id: UUID) {
        lock.withLock {
            guard browseOperationID == id else { return }
            browseOperationID = nil
            browseHandler = nil
            browseCancellationCount += 1
        }
    }

    private func cancelResolve(id: UUID) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard resolves.removeValue(forKey: id) != nil,
                  cancelledResolveIDs.insert(id).inserted else { return [] }
            let waiters = cancellationWaiters
            cancellationWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

private struct TestBonjourClock: CmxIrohBonjourClock {
    private let fixedNow: Date
    private let state = TestBonjourClockState()

    init(now: Date) {
        fixedNow = now
    }

    func now() -> Date { fixedNow }

    func sleep(until deadline: Date) async throws {
        try await state.sleep(until: deadline)
    }

    func advance(by interval: TimeInterval) async {
        await state.advance(to: fixedNow.addingTimeInterval(interval))
    }

    func pendingSleepCount() async -> Int {
        await state.pendingSleepCount()
    }

    func waitForPendingSleepCount(_ expectedCount: Int) async {
        await state.waitForPendingSleepCount(expectedCount)
    }

    func waitUntilIdle() async {
        await state.waitUntilIdle()
    }
}

private actor TestBonjourClockState {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct CountWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var sleepers: [UUID: Sleeper] = [:]
    private var countWaiters: [UUID: CountWaiter] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                resumeCountWaitersIfNeeded()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance(to date: Date) {
        let ready = sleepers.filter { $0.value.deadline <= date }
        for id in ready.keys { sleepers[id] = nil }
        for sleeper in ready.values { sleeper.continuation.resume() }
        resumeIdleWaitersIfNeeded()
    }

    func pendingSleepCount() -> Int { sleepers.count }

    func waitForPendingSleepCount(_ expectedCount: Int) async {
        guard sleepers.count < expectedCount else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || sleepers.count >= expectedCount {
                    continuation.resume()
                } else {
                    countWaiters[id] = CountWaiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelCountWaiter(id) }
        }
    }

    func waitUntilIdle() async {
        guard !sleepers.isEmpty else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || sleepers.isEmpty {
                    continuation.resume()
                } else {
                    idleWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelIdleWaiter(id) }
        }
    }

    private func cancel(id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        sleeper.continuation.resume(throwing: CancellationError())
        resumeIdleWaitersIfNeeded()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard sleepers.isEmpty else { return }
        let waiters = idleWaiters.values
        idleWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func resumeCountWaitersIfNeeded() {
        let readyIDs = countWaiters.compactMap { id, waiter in
            sleepers.count >= waiter.expectedCount ? id : nil
        }
        let ready = readyIDs.compactMap { countWaiters.removeValue(forKey: $0) }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func cancelCountWaiter(_ id: UUID) {
        countWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func cancelIdleWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume()
    }
}
