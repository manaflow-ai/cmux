/// Poll until `condition` is true, bounded at `attempts` x 10ms. The default
/// budget is intentionally generous for whole-suite scheduling; callers that
/// assert bounded absence can keep an explicit shorter attempt count. Returns
/// the final value so tests can assert both presence and (bounded) absence.
@MainActor
func pollUntil(
    attempts: Int = MobileShellWallClockWaitPolicy.defaultPollAttempts,
    _ condition: @escaping @MainActor @Sendable () async -> Bool
) async throws -> Bool {
    let operation: @Sendable () async throws -> Bool = {
        try Task.checkCancellation()
        for _ in 0..<attempts {
            if await condition() {
                return true
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
    if MobileShellWallClockWaitPolicy.shouldSerializePoll(attempts: attempts) {
        return try await MobileShellWallClockWaitGate.processWide.withLock(operation)
    }
    return try await operation()
}
