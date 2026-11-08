import Foundation

actor MobileTaskModelPrefetchCatalogProbe {
    let data: Data
    private(set) var requestCount = 0
    private var hold = false
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(data: Data) {
        self.data = data
    }

    func setHold(_ hold: Bool) {
        self.hold = hold
    }

    func load() async -> Data {
        requestCount += 1
        if hold {
            started = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { releaseContinuations.append($0) }
        }
        return data
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
