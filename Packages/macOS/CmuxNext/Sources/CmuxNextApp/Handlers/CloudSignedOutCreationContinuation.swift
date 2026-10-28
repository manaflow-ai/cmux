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

    /// Hosted auth publishes its user before loading the initial active team.
    /// That nil-to-team hydration belongs to the sign-in we are awaiting.
    /// A later user replacement, sign-out, or populated-team change does not.
    func scopeDidChange(from previous: [String?], to current: [String?]) {
        guard isPending else { return }
        if previous == [nil, nil], current[0] != nil { return }
        if previous[0] != nil, previous[0] == current[0], previous[1] == nil, current[1] != nil { return }
        cancel()
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    var isPending: Bool { task != nil }
}
