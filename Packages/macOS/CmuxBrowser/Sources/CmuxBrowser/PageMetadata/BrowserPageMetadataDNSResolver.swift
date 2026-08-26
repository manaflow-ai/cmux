import CmuxFoundation
import Foundation

/// Bounds blocking system DNS work while allowing canceled fetches to return promptly.
actor BrowserPageMetadataDNSResolver: BrowserPageMetadataResolving {
    private let worker: BrowserPageMetadataDNSWorker
    private let maximumConcurrentQueries: Int
    private var runningQueryCount = 0
    private var queries: [UUID: BrowserPageMetadataDNSQuery] = [:]

    init(
        addressPolicy: NetworkAddressPolicy = NetworkAddressPolicy(),
        maximumConcurrentQueries: Int = 4
    ) {
        self.worker = BrowserPageMetadataDNSWorker(addressPolicy: addressPolicy)
        self.maximumConcurrentQueries = max(1, maximumConcurrentQueries)
    }

    func addresses(for host: String) async -> [BrowserPageMetadataResolvedAddress] {
        guard runningQueryCount < maximumConcurrentQueries else { return [] }
        let queryID = UUID()
        let worker = worker
        runningQueryCount += 1

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queries[queryID] = BrowserPageMetadataDNSQuery(continuation: continuation)
                worker.resolve(host: host) { [weak self] addresses in
                    Task { await self?.completeQuery(queryID, addresses: addresses) }
                }
                if Task.isCancelled {
                    cancelQuery(queryID)
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelQuery(queryID) }
        }
    }

    private func cancelQuery(_ queryID: UUID) {
        guard var query = queries[queryID], let continuation = query.continuation else { return }
        query.continuation = nil
        queries[queryID] = query
        continuation.resume(returning: [])
    }

    private func completeQuery(
        _ queryID: UUID,
        addresses: [BrowserPageMetadataResolvedAddress]
    ) {
        guard let query = queries.removeValue(forKey: queryID) else { return }
        runningQueryCount = max(0, runningQueryCount - 1)
        query.continuation?.resume(returning: addresses)
    }
}
