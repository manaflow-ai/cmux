/// Serializes a multi-call paired-Mac mutation across actor suspension points.
/// The underlying SQLite actor makes each individual call atomic; scope
/// decorators use this gate when one logical mutation spans multiple calls.
actor PairedMacMutationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}
