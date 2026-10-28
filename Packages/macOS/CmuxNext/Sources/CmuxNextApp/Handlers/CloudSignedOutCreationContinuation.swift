import CmuxNextActions

/// Owns one person-initiated creation while hosted Cloud sign-in is pending.
/// Replacement, sign-out, and policy changes invalidate the previous generation.
@MainActor
final class CloudSignedOutCreationContinuation {
    private var generation = 0
    private var pendingGeneration: Int?
    private var task: Task<Void, Never>?

    /// The auth attempt has its own bounded lifetime. Cancelling this waiter
    /// leaves that shared attempt alone, but never resumes its creation.
    @discardableResult
    func replace(
        signIn: @escaping @MainActor () async -> Bool,
        resume: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        let expected = reserve()
        let pending = Task { @MainActor [weak self] in
            _ = await self?.perform(expected: expected, signIn: signIn, resume: resume)
        }
        task = pending
        return pending
    }

    /// Reserves one replay generation synchronously, before an action hands its
    /// asynchronous sign-in work to ActionRegistry.
    func reserve() -> Int {
        cancel()
        pendingGeneration = generation
        return generation
    }

    func effect(signIn: @escaping @MainActor () async -> Bool,
                resume: @escaping @MainActor () -> Void) -> ActionEffect {
        let expected = reserve()
        // action-wait-allow: hosted authentication must succeed before provisioning; the registry owns this wait.
        return .waiting(.network) {
            let resumed = await withTaskCancellationHandler {
                await self.perform(expected: expected, signIn: signIn, resume: resume)
            } onCancel: {
                // task-owner: a one-shot cancellation hop invalidates only this generation.
                Task { @MainActor in self.cancel(expected: expected) }
            }
            return resumed ? nil : ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.signInFirst)
        }
    }

    /// Completes a reserved sign-in. The registry owns cancellation of this
    /// operation; a stale generation can never replay the captured creation.
    @discardableResult
    func perform(
        expected: Int,
        signIn: @escaping @MainActor () async -> Bool,
        resume: @escaping @MainActor () -> Void
    ) async -> Bool {
        guard pendingGeneration == expected, generation == expected, !Task.isCancelled else {
            cancel(expected: expected)
            return false
        }
        let succeeded = await signIn()
        guard pendingGeneration == expected, generation == expected else { return false }
        pendingGeneration = nil
        task = nil
        guard succeeded, !Task.isCancelled else {
            generation += 1
            return false
        }
        // Consume before calling out; replay may itself start another intent.
        generation += 1
        resume()
        return true
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
        pendingGeneration = nil
        task?.cancel()
        task = nil
    }

    func cancel(expected: Int) {
        guard pendingGeneration == expected, generation == expected else { return }
        cancel()
    }

    var isPending: Bool { pendingGeneration != nil }
}
