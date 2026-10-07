/// Resumes a continuation once; later results are dropped.
actor OnceGate<T: Sendable> {
    private var done = false

    @discardableResult
    func resume(_ continuation: CheckedContinuation<T, any Error>, with result: Result<T, any Error>) -> Bool {
        guard !done else { return false }
        done = true
        continuation.resume(with: result)
        return true
    }
}
