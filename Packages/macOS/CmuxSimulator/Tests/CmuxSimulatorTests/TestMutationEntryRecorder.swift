actor TestMutationEntryRecorder {
    private(set) var values: [String] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ value: String) {
        values.append(value)
        let ready = countWaiters.filter { values.count >= $0.0 }
        countWaiters.removeAll { values.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
    }

    func waitUntilCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }
}
