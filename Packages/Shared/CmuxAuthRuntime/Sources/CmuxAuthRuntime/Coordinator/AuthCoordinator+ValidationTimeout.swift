import Foundation

@MainActor
extension AuthCoordinator {
    func runValidationPhase<T: Sendable>(
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let validationID = UUID()
        guard await phaseTimeoutRegistry.begin(.validateSession, id: validationID) else {
            log.log("auth.phase=\(AuthPhase.validateSession.rawValue) previous timed-out validation still active")
            throw AuthError.timedOut
        }

        let generation = sessionGeneration
        let signOutEpoch = signOutEpoch
        let storeWriteHighWater = tokenStoreWriteHighWater
        let registry = phaseTimeoutRegistry
        let validation = Task {
            let result: Result<T, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            try await finishValidationPhase(
                generation: generation,
                signOutEpoch: signOutEpoch,
                storeWriteHighWater: storeWriteHighWater
            )
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }
        let completion = Task { [weak self, registry, validationID] in
            _ = await validation.result
            await registry.end(.validateSession, id: validationID)
            await MainActor.run {
                self?.activeSessionValidations[validationID] = nil
            }
        }
        activeSessionValidations[validationID] = AuthTrackedTokenWork(
            cancel: { validation.cancel() },
            completion: completion
        )

        return try await withTaskCancellationHandler {
            try await waitForValidationPhase(validation, id: validationID, timeout: timeout)
        } onCancel: {
            validation.cancel()
        }
    }

    private func waitForValidationPhase<T: Sendable>(
        _ validation: Task<T, any Error>,
        id: UUID,
        timeout: Duration
    ) async throws -> T {
        try Task.checkCancellation()
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncThrowingStream<T, any Error> { continuation in
            let validationWaiter = Task {
                do {
                    let value = try await validation.value
                    await phaseTimeoutRegistry.end(.validateSession, id: id)
                    guard await race.winOperation() else { return }
                    continuation.yield(value)
                    continuation.finish()
                } catch {
                    await phaseTimeoutRegistry.end(.validateSession, id: id)
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
                log.log("auth.phase=\(AuthPhase.validateSession.rawValue) timed out after \(timeout)")
                await phaseTimeoutRegistry.markTimedOut(.validateSession, id: id)
                validation.cancel()
                continuation.finish(throwing: AuthError.timedOut)
            }
            continuation.onTermination = { _ in
                validationWaiter.cancel()
                deadline.cancel()
            }
        }
        do {
            for try await value in stream {
                return value
            }
        } catch {
            throw error
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        throw AuthError.timedOut
    }

    private func finishValidationPhase(
        generation: UInt64,
        signOutEpoch: UInt64,
        storeWriteHighWater: UInt64
    ) async throws {
        guard signOutEpoch != self.signOutEpoch else { return }
        await waitForSignOutCredentialCapture()
        guard tokenStoreWriteHighWater == storeWriteHighWater else {
            throw CancellationError()
        }
        let refreshTokenAfterValidation = await client.refreshToken()
        var clearedStaleRefreshToken = false
        if let refreshTokenAfterValidation,
           refreshTokenAfterValidation != latestSignInRefreshToken {
            await client.clearLocalSession(ifRefreshTokenMatches: refreshTokenAfterValidation)
            clearedStaleRefreshToken = await client.refreshToken() == nil
        }
        guard generation == sessionGeneration,
              tokenStoreWriteHighWater == storeWriteHighWater else {
            if clearedStaleRefreshToken, isAuthenticated {
                clearAuthState(preservePendingCode: true)
            }
            throw CancellationError()
        }
        clearAuthState(preservePendingCode: true)
        throw CancellationError()
    }

}
