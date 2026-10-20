import Foundation

extension AuthCoordinator {
    /// Bound the post-sign-in hook without losing ownership of the hook task.
    ///
    /// The hook performs side effects above this package, such as push-token
    /// registration. If it ignores cancellation after its UI deadline, sign-in
    /// must still return, but sign-out must retain a task handle so it can
    /// cancel the late hook before clearing the session.
    func runPostSignInHook(
        timeout: Duration,
        _ operation: @escaping @Sendable () async -> Void
    ) async {
        let id = UUID()
        let hookTask = Task {
            await operation()
        }
        let completion = Task {
            await hookTask.value
        }
        activePostSignInHooks[id] = AuthTrackedTokenWork(
            cancel: { hookTask.cancel() },
            completion: completion
        )

        Task { [weak self, completion] in
            await completion.value
            await MainActor.run { [weak self] in
                self?.activePostSignInHooks[id] = nil
            }
        }

        do {
            try await waitForPostSignInHook(hookTask, timeout: timeout)
            activePostSignInHooks[id] = nil
        } catch AuthError.timedOut {
            hookTask.cancel()
        } catch {
            hookTask.cancel()
        }
    }

    func cancelPostSignInHooksForSignOut() {
        let hooks = Array(activePostSignInHooks.values)
        for hook in hooks {
            hook.cancel()
        }
    }

    func waitForPostSignInHooksAfterSignOut(timeout: Duration) async {
        let hooks = Array(activePostSignInHooks.values)
        guard !hooks.isEmpty else { return }
        await waitForPostSignInHookCompletionsBeforeSignOut(
            hooks.map(\.completion),
            timeout: timeout
        )
    }

    private func waitForPostSignInHook(
        _ hookTask: Task<Void, Never>,
        timeout: Duration
    ) async throws {
        try Task.checkCancellation()
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncThrowingStream<Void, any Error> { continuation in
            let hookWaiter = Task {
                await hookTask.value
                guard await race.winOperation() else { return }
                continuation.yield(())
                continuation.finish()
            }
            let deadline = Task { [clock, log] in
                do {
                    try await clock.sleep(for: timeout, tolerance: nil)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard await race.winTimeout() else { return }
                log.log("auth.phase=\(AuthPhase.postSignIn.rawValue) timed out after \(timeout)")
                hookTask.cancel()
                continuation.finish(throwing: AuthError.timedOut)
            }
            continuation.onTermination = { _ in
                hookWaiter.cancel()
                deadline.cancel()
            }
        }

        for try await _ in stream {
            return
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        throw AuthError.timedOut
    }

    private func waitForPostSignInHookCompletionsBeforeSignOut(
        _ completions: [Task<Void, Never>],
        timeout: Duration
    ) async {
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncStream<Void> { continuation in
            let join = Task {
                for completion in completions {
                    await completion.value
                }
                guard await race.winOperation() else { return }
                continuation.yield(())
                continuation.finish()
            }
            let deadline = Task { [clock, log] in
                do {
                    try await clock.sleep(for: timeout, tolerance: nil)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard await race.winTimeout() else { return }
                log.log("auth.phase=\(AuthPhase.postSignIn.rawValue) sign-out join timed out after \(timeout)")
                continuation.yield(())
                continuation.finish()
            }
            continuation.onTermination = { _ in
                join.cancel()
                deadline.cancel()
            }
        }

        for await _ in stream {
            return
        }
    }
}
