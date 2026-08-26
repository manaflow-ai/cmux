actor ControllablePageMetadataDNSWorker: BrowserPageMetadataDNSWorking {
    typealias Completion = @Sendable ([BrowserPageMetadataResolvedAddress]) -> Void

    private var completionsByHost: [String: Completion] = [:]
    private var startedHosts: [String] = []
    private var startWaiters: [(
        count: Int,
        continuation: CheckedContinuation<[String], Never>
    )] = []

    nonisolated func resolve(host: String, completion: @escaping Completion) {
        Task { await recordStart(host: host, completion: completion) }
    }

    func waitForStartedQueryCount(_ count: Int) async -> [String] {
        if startedHosts.count >= count {
            return startedHosts
        }
        return await withCheckedContinuation { continuation in
            startWaiters.append((count: count, continuation: continuation))
        }
    }

    func complete(
        host: String,
        addresses: [BrowserPageMetadataResolvedAddress]
    ) {
        completionsByHost.removeValue(forKey: host)?(addresses)
    }

    func recordedStartedHosts() -> [String] {
        startedHosts
    }

    private func recordStart(host: String, completion: @escaping Completion) {
        completionsByHost[host] = completion
        startedHosts.append(host)
        let snapshot = startedHosts
        var ready: [CheckedContinuation<[String], Never>] = []
        startWaiters.removeAll { waiter in
            guard snapshot.count >= waiter.count else { return false }
            ready.append(waiter.continuation)
            return true
        }
        for continuation in ready {
            continuation.resume(returning: snapshot)
        }
    }
}
