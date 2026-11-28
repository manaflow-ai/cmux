/// Owns the bounded failure deadline for one remote-image request.
/// Successful completion cancels the returned task; network callbacks own
/// completion and the clock is consulted only to expire an unfinished request.
struct MarkdownImageLoadDeadline<C: Clock>: Sendable where C.Duration == Duration {
    let clock: C
    let timeout: Duration

    func schedule(_ expire: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let deadline = clock.now.advanced(by: timeout)
        return Task {
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
                try Task.checkCancellation()
            } catch {
                return
            }
            expire()
        }
    }
}
