/// Owns one person-initiated creation while hosted Cloud sign-in is pending.
/// Replacement, sign-out, and policy changes invalidate the previous generation.
@MainActor
final class CloudSignedOutCreationContinuation {
    private var generation = 0
    private var task: Task<Void, Never>?

    /// The auth attempt has its own bounded lifetime. Cancelling this waiter
    /// leaves that shared attempt alone, but never resumes its creation.
    @discardableResult
    func replace(
        signIn: @escaping @MainActor () async -> Bool,
        resume: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        cancel()
        let expected = generation
        let pending = Task { @MainActor [weak self] in
            let succeeded = await signIn()
            guard let self, self.generation == expected else { return }
            self.task = nil
            guard succeeded, !Task.isCancelled else { return }
            // Consume before calling out; replay may itself start another intent.
            self.generation += 1
            resume()
        }
        task = pending
        return pending
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    var isPending: Bool { task != nil }
}
