import CmuxNextApps
import CmuxNextDaemon

/// Records actual publication attempts and can delay an acknowledgement without a timer.
actor CatalogTestWriter: MachineCatalogWriter {
    nonisolated let attempts: AsyncStream<MachineCatalogPublishRequest>
    private let events: AsyncStream<MachineCatalogPublishRequest>.Continuation
    private let pause: @Sendable () async -> Void
    private var failures: [DaemonError?]
    private(set) var requests: [MachineCatalogPublishRequest] = []

    init(failures: [DaemonError?] = [], pause: @escaping @Sendable () async -> Void = {}) {
        let stream = AsyncStream<MachineCatalogPublishRequest>.makeStream()
        attempts = stream.stream
        events = stream.continuation
        self.failures = failures
        self.pause = pause
    }

    func publishMachineCatalog(_ request: MachineCatalogPublishRequest) async throws {
        requests.append(request)
        events.yield(request)
        await pause()
        if !failures.isEmpty, let error = failures.removeFirst() { throw error }
    }
}
