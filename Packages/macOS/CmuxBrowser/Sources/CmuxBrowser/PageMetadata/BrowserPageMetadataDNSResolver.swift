import CmuxFoundation
import Foundation

/// Bounds blocking system DNS work while allowing canceled fetches to return promptly.
actor BrowserPageMetadataDNSResolver: BrowserPageMetadataResolving {
    private let worker: any BrowserPageMetadataDNSWorking
    private let maximumConcurrentQueries: Int
    private let maximumPendingQueries: Int
    private var runningQueryCount = 0
    private var queries: [UUID: BrowserPageMetadataDNSQuery] = [:]
    private var pendingQueryIDs: [UUID] = []

    /// The bounded number of requests currently waiting for a worker slot.
    var pendingQueryCount: Int {
        pendingQueryIDs.count
    }

    init(
        addressPolicy: NetworkAddressPolicy = NetworkAddressPolicy(),
        maximumConcurrentQueries: Int = 4,
        maximumPendingQueries: Int = 64
    ) {
        self.worker = BrowserPageMetadataDNSWorker(addressPolicy: addressPolicy)
        self.maximumConcurrentQueries = max(1, maximumConcurrentQueries)
        self.maximumPendingQueries = max(0, maximumPendingQueries)
    }

    init(
        worker: any BrowserPageMetadataDNSWorking,
        maximumConcurrentQueries: Int = 4,
        maximumPendingQueries: Int = 64
    ) {
        self.worker = worker
        self.maximumConcurrentQueries = max(1, maximumConcurrentQueries)
        self.maximumPendingQueries = max(0, maximumPendingQueries)
    }

    func addresses(for host: String) async -> [BrowserPageMetadataResolvedAddress] {
        let queryID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueueQuery(queryID, host: host, continuation: continuation)
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelQuery(queryID) }
        }
    }

    private func enqueueQuery(
        _ queryID: UUID,
        host: String,
        continuation: CheckedContinuation<[BrowserPageMetadataResolvedAddress], Never>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(returning: [])
            return
        }
        queries[queryID] = BrowserPageMetadataDNSQuery(
            host: host,
            continuation: continuation
        )
        if runningQueryCount < maximumConcurrentQueries {
            startQuery(queryID)
        } else if pendingQueryIDs.count < maximumPendingQueries {
            pendingQueryIDs.append(queryID)
        } else {
            queries[queryID] = nil
            continuation.resume(returning: [])
        }
    }

    private func cancelQuery(_ queryID: UUID) {
        guard var query = queries[queryID], let continuation = query.continuation else { return }
        query.continuation = nil
        if query.isRunning {
            queries[queryID] = query
        } else {
            queries[queryID] = nil
            pendingQueryIDs.removeAll { $0 == queryID }
        }
        continuation.resume(returning: [])
    }

    private func completeQuery(
        _ queryID: UUID,
        addresses: [BrowserPageMetadataResolvedAddress]
    ) {
        guard let query = queries.removeValue(forKey: queryID), query.isRunning else { return }
        runningQueryCount = max(0, runningQueryCount - 1)
        query.continuation?.resume(returning: addresses)
        startPendingQueries()
    }

    private func startPendingQueries() {
        while runningQueryCount < maximumConcurrentQueries, !pendingQueryIDs.isEmpty {
            let queryID = pendingQueryIDs.removeFirst()
            guard queries[queryID] != nil else { continue }
            startQuery(queryID)
        }
    }

    private func startQuery(_ queryID: UUID) {
        guard var query = queries[queryID], !query.isRunning else { return }
        query.isRunning = true
        queries[queryID] = query
        runningQueryCount += 1
        worker.resolve(host: query.host) { [weak self] addresses in
            Task { await self?.completeQuery(queryID, addresses: addresses) }
        }
    }
}
