actor BrowserWebExtensionTestGate<Value: Sendable> {
    private var continuations: [CheckedContinuation<Value, Never>] = []

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(with value: Value) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: value)
        }
    }
}
