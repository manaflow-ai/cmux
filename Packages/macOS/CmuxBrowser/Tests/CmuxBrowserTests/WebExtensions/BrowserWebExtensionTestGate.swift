actor BrowserWebExtensionTestGate<Value: Sendable> {
    private var continuations: [CheckedContinuation<Value, Never>] = []
    private var bufferedValues: [Value] = []

    func wait() async -> Value {
        if !bufferedValues.isEmpty {
            return bufferedValues.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(with value: Value) {
        guard !continuations.isEmpty else {
            bufferedValues.append(value)
            return
        }
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: value)
        }
    }
}
