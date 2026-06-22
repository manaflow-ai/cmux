import Foundation

@MainActor
extension AuthCoordinator {
    /// Run a sign-in flow's credential exchange as a coordinator-owned child
    /// task registered under the flow's attempt id, racing the phase deadline
    /// like ``runPhase(_:timeout:_:)``.
    ///
    /// The registration is what makes sign-out able to win against a parked
    /// exchange: ``signOut(onSignedOut:teardownTimeout:)`` cancels every
    /// registered exchange before clearing local state, and the SDK's write
    /// chokepoint drops the token store write of a cancelled flow, so the
    /// stale exchange can neither resurrect the signed-out session nor
    /// clobber a newer sign-in's freshly written tokens. Caller cancellation
    /// is forwarded to the child task.
    func runExchange(
        _ phase: AuthPhase,
        flow: SignInFlowContext,
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let exchangeID = UUID()
        guard await phaseTimeoutRegistry.begin(phase, id: exchangeID) else {
            log.log("auth.phase=\(phase.rawValue) previous timed-out exchange still active")
            throw AuthError.timedOut
        }
        let registry = phaseTimeoutRegistry
        let client = self.client
        let exchange = Task {
            try await operation()
            let refreshToken = await client.refreshToken()
            if Task.isCancelled {
                if let refreshToken {
                    await waitForSignOutCredentialCapture()
                    await client.clearLocalSession(ifRefreshTokenMatches: refreshToken)
                }
                throw CancellationError()
            }
            return refreshToken
        }
        let completion = Task {
            _ = await exchange.result
        }
        activeSignInExchanges[flow.attempt] = AuthTrackedSignInExchange(
            id: exchangeID,
            task: exchange,
            completion: completion
        )
        Task { [weak self, registry, attempt = flow.attempt, exchangeID, phase] in
            await completion.value
            await registry.end(phase, id: exchangeID)
            await MainActor.run {
                guard self?.activeSignInExchanges[attempt]?.id == exchangeID else { return }
                self?.activeSignInExchanges[attempt] = nil
            }
        }
        try await withTaskCancellationHandler {
            try await waitForExchange(exchange, id: exchangeID, attempt: flow.attempt, phase: phase, timeout: timeout)
        } onCancel: {
            Task { await registry.markTimedOut(phase, id: exchangeID) }
            exchange.cancel()
        }
    }

    private func waitForExchange(
        _ exchange: Task<String?, any Error>,
        id: UUID,
        attempt: UInt64,
        phase: AuthPhase,
        timeout: Duration
    ) async throws {
        try Task.checkCancellation()
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncThrowingStream<Void, any Error> { continuation in
            let exchangeWaiter = Task {
                do {
                    let refreshToken = try await exchange.value
                    guard await race.winOperation() else {
                        if let refreshToken {
                            await waitForSignOutCredentialCapture()
                            await self.client.clearLocalSession(ifRefreshTokenMatches: refreshToken)
                        }
                        return
                    }
                    await phaseTimeoutRegistry.end(phase, id: id)
                    tokenStoreWriteHighWater = max(tokenStoreWriteHighWater, attempt)
                    latestSignInRefreshToken = refreshToken
                    continuation.yield(())
                    continuation.finish()
                } catch {
                    await phaseTimeoutRegistry.end(phase, id: id)
                    guard await race.winOperation() else { return }
                    continuation.finish(throwing: error)
                }
            }
            let deadline = Task { [clock, log] in
                do {
                    try await clock.sleep(for: timeout, tolerance: nil)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard await race.winTimeout() else { return }
                log.log("auth.phase=\(phase.rawValue) timed out after \(timeout)")
                await phaseTimeoutRegistry.markTimedOut(phase, id: id)
                exchange.cancel()
                continuation.finish(throwing: AuthError.timedOut)
            }
            continuation.onTermination = { _ in
                exchangeWaiter.cancel()
                deadline.cancel()
            }
        }
        do {
            for try await _ in stream {
                return
            }
        } catch AuthError.timedOut {
            throw AuthError.timedOut
        } catch {
            throw error
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        throw AuthError.timedOut
    }
}
