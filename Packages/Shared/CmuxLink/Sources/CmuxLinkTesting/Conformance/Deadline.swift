/// Runs `operation`, failing with `ConformanceFailure` after `limit` of real
/// time so a broken carrier fails instead of hanging the suite. The
/// operation runs unstructured: a step stuck in a non-cancellable wait is
/// abandoned rather than awaited.
struct Deadline: Sendable {
    let limit: Duration
    let harness: String
    let testCase: ConformanceCase?

    @discardableResult
    func run<T: Sendable>(
        _ what: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let limit = limit
        let failure = ConformanceFailure(harness: harness, testCase: testCase, message: "timed out: \(what)")
        let gate = OnceGate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do {
                    let value = try await operation()
                    await gate.resume(continuation, with: .success(value))
                } catch {
                    await gate.resume(continuation, with: .failure(error))
                }
            }
            Task {
                try? await ContinuousClock().sleep(for: limit)
                if await gate.resume(continuation, with: .failure(failure)) { work.cancel() }
            }
        }
    }
}
