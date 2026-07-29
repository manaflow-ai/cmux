import CmuxMobileRPC
import Foundation

@MainActor
final class MobileTerminalInputRPCPipeline {
    typealias SettlementHandler = @MainActor (
        Result<Data, any Error>
    ) -> Void

    private struct Entry {
        let id: UUID
        let request: MobileCoreRPCPipelinedRequest
        let settlementHandler: SettlementHandler
    }

    private static let maximumUnsettledRequestCount = 4

    private var entries: [Entry] = []
    private var capacityWaiters: [CheckedContinuation<Void, Never>] = []
    private var allSettledWaiters: [CheckedContinuation<Void, Never>] = []
    private var reaperTask: Task<Void, Never>?
    private var generation = UUID()

    var hasUnsettledRequests: Bool { !entries.isEmpty }

    func enqueue(
        makeRequest: @MainActor () async throws -> MobileCoreRPCPipelinedRequest,
        settlementHandler: @escaping SettlementHandler
    ) async throws {
        let enqueueGeneration = generation
        while entries.count >= Self.maximumUnsettledRequestCount {
            await withCheckedContinuation { continuation in
                capacityWaiters.append(continuation)
            }
            guard generation == enqueueGeneration else {
                throw CancellationError()
            }
        }
        let request = try await makeRequest()
        guard generation == enqueueGeneration else {
            throw CancellationError()
        }
        entries.append(Entry(
            id: UUID(),
            request: request,
            settlementHandler: settlementHandler
        ))
        startReaperIfNeeded()
    }

    func waitUntilAllSettled() async {
        guard !entries.isEmpty else { return }
        await withCheckedContinuation { continuation in
            allSettledWaiters.append(continuation)
        }
    }

    func clear() {
        generation = UUID()
        let abandonedEntries = entries
        entries.removeAll()
        reaperTask?.cancel()
        reaperTask = nil
        // Dropped entries are never awaited again; release their session
        // settlement slots instead of leaving them to sit until the request
        // deadline (or, once settled, until session teardown). The reaper's
        // cancellation already abandons the head entry; a second abandon is a
        // no-op.
        for entry in abandonedEntries {
            let request = entry.request
            Task { await request.abandon() }
        }
        resumeCapacityWaiters()
        resumeAllSettledWaiters()
    }

    private func startReaperIfNeeded() {
        guard reaperTask == nil else { return }
        let reaperGeneration = generation
        reaperTask = Task { @MainActor [weak self] in
            await self?.reapResponses(generation: reaperGeneration)
        }
    }

    private func reapResponses(generation reaperGeneration: UUID) async {
        while generation == reaperGeneration, let entry = entries.first {
            let result: Result<Data, any Error>
            do {
                result = .success(try await entry.request.response())
            } catch {
                result = .failure(error)
            }
            guard generation == reaperGeneration,
                  entries.first?.id == entry.id else {
                return
            }
            entries.removeFirst()
            entry.settlementHandler(result)
            // One settlement frees exactly one slot; waking only the
            // longest-parked producer keeps enqueue arrival order even if a
            // second producer ever appears. clear() still wakes everyone.
            resumeNextCapacityWaiter()
        }
        guard generation == reaperGeneration else { return }
        reaperTask = nil
        if entries.isEmpty {
            resumeAllSettledWaiters()
        } else {
            startReaperIfNeeded()
        }
    }

    private func resumeNextCapacityWaiter() {
        guard !capacityWaiters.isEmpty else { return }
        capacityWaiters.removeFirst().resume()
    }

    private func resumeCapacityWaiters() {
        let waiters = capacityWaiters
        capacityWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeAllSettledWaiters() {
        let waiters = allSettledWaiters
        allSettledWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
