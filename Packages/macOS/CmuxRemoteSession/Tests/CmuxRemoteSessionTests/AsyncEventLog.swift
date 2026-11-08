actor AsyncEventLog {
    private(set) var values: [String] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ value: String) {
        values.append(value)
        let ready = countWaiters.filter { values.count >= $0.count }
        countWaiters.removeAll { values.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitForCount(_ count: Int) async {
        if values.count >= count { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }
}
