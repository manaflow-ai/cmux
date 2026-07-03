import Foundation

@MainActor
extension AuthCoordinator {
    func runTokenTouchingPhase<T: Sendable>(
        _ phase: AuthPhase,
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        expireTimedOutTokenTouchingPhaseIfNeeded(phase)
        guard timedOutTokenTouchingPhaseStates[phase] == nil else {
            log.log("auth.phase=\(phase.rawValue) previous timed-out token work still active")
            throw AuthError.timedOut
        }
        let phaseID = UUID()
        let generation = sessionGeneration
        let signOutEpoch = signOutEpoch
        let storeWriteHighWater = tokenStoreWriteHighWater
        let phaseTask = Task {
            let result: Result<T, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            try await finishTokenTouchingPhase(
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
        let completion = Task { [weak self, phaseID] in
            _ = await phaseTask.result
            await MainActor.run {
                if self?.timedOutTokenTouchingPhaseStates[phase]?.id == phaseID {
                    self?.timedOutTokenTouchingPhaseStates[phase] = nil
                }
                self?.activeTokenTouchingPhases[phaseID] = nil
                self?.abandonedTokenTouchingPhaseIDs.remove(phaseID)
            }
        }
        activeTokenTouchingPhases[phaseID] = AuthTrackedTokenWork(
            cancel: { phaseTask.cancel() },
            completion: completion
        )

        return try await withTaskCancellationHandler {
            try await waitForTokenTouchingPhase(
                phaseTask,
                id: phaseID,
                phase: phase,
                timeout: timeout
            )
        } onCancel: {
            phaseTask.cancel()
            Task { @MainActor [weak self] in
                self?.gateTokenTouchingPhase(phase, id: phaseID)
            }
        }
    }

    private func waitForTokenTouchingPhase<T: Sendable>(
        _ phaseTask: Task<T, any Error>,
        id: UUID,
        phase: AuthPhase,
        timeout: Duration
    ) async throws -> T {
        try Task.checkCancellation()
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncThrowingStream<T, any Error> { continuation in
            let phaseWaiter = Task {
                do {
                    let value = try await phaseTask.value
                    guard await race.winOperation() else { return }
                    continuation.yield(value)
                    continuation.finish()
                } catch {
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
                await MainActor.run {
                    gateTokenTouchingPhase(phase, id: id)
                }
                phaseTask.cancel()
                continuation.finish(throwing: AuthError.timedOut)
            }
            continuation.onTermination = { _ in
                phaseWaiter.cancel()
                deadline.cancel()
            }
        }

        do {
            for try await value in stream {
                return value
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

    private func gateTokenTouchingPhase(_ phase: AuthPhase, id: UUID) {
        guard activeTokenTouchingPhases[id] != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        timedOutTokenTouchingPhaseStates[phase] = AuthPhaseTimedOutState(
            id: id,
            expiresAt: now &+ tokenTouchingTimedOutResetNanoseconds,
            hardExpiresAt: now &+ tokenTouchingHardExpiryNanoseconds
        )
    }

    private func expireTimedOutTokenTouchingPhaseIfNeeded(_ phase: AuthPhase) {
        guard let timedOut = timedOutTokenTouchingPhaseStates[phase] else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= timedOut.expiresAt else { return }
        // Normal path: reopen once the previous timed-out phase task has
        // finished unwinding, so a slow-but-honest cancellation does not start a
        // second concurrent token operation.
        if activeTokenTouchingPhases[timedOut.id] == nil {
            timedOutTokenTouchingPhaseStates[phase] = nil
            return
        }
        // Safety net: a Stack SDK call that hangs and ignores cancellation never
        // lets the previous phase task finish, which would keep this phase — and
        // therefore token acquisition for every session — gated forever. Reopen
        // once the bounded hard window elapses so the next caller can retry,
        // matching AuthPhaseTimeoutRegistry's time-based recovery (#6311).
        //
        // Detach one wedged task from coordinator-owned active work before
        // reopening, otherwise repeated hard-expiry retries would retain an
        // unbounded chain of never-finishing tasks. If that detached task also
        // never completes, keep the phase gated after the current retry until
        // cleanup frees the abandoned slot. The detached task still runs its own
        // stale-completion guard if it ever resumes, so a late SDK token write
        // cannot survive a newer session/sign-in transition.
        guard let hardExpiresAt = timedOut.hardExpiresAt, now >= hardExpiresAt else { return }
        guard abandonedTokenTouchingPhaseIDs.count < maxAbandonedTokenTouchingPhases else {
            return
        }
        if let work = activeTokenTouchingPhases.removeValue(forKey: timedOut.id) {
            work.cancel()
            abandonedTokenTouchingPhaseIDs.insert(timedOut.id)
        }
        timedOutTokenTouchingPhaseStates[phase] = nil
    }

    private func finishTokenTouchingPhase(
        generation: UInt64,
        signOutEpoch: UInt64,
        storeWriteHighWater: UInt64
    ) async throws {
        let signOutBeganAfterPhaseStart = signOutEpoch != self.signOutEpoch
        let sessionMovedAfterPhaseStart = generation != sessionGeneration
        let tokenStoreOwnerMovedAfterPhaseStart = tokenStoreWriteHighWater != storeWriteHighWater
        guard signOutBeganAfterPhaseStart
            || sessionMovedAfterPhaseStart
            || tokenStoreOwnerMovedAfterPhaseStart else {
            return
        }
        if signOutBeganAfterPhaseStart {
            await waitForSignOutCredentialCapture()
        }
        let refreshTokenAfterOperation = await client.refreshToken()
        var clearedStaleRefreshToken = false
        if let refreshTokenAfterOperation,
           refreshTokenAfterOperation != latestSignInRefreshToken {
            await client.clearLocalSession(ifRefreshTokenMatches: refreshTokenAfterOperation)
            clearedStaleRefreshToken = await client.refreshToken() == nil
        }
        guard !signOutBeganAfterPhaseStart,
              generation == sessionGeneration,
              tokenStoreWriteHighWater == storeWriteHighWater else {
            if clearedStaleRefreshToken, isAuthenticated {
                clearAuthState(preservePendingCode: true)
            }
            throw CancellationError()
        }
        throw CancellationError()
    }

    func waitForSignOutCredentialCapture() async {
        guard isCapturingSignOutCredentials else { return }
        await withCheckedContinuation { continuation in
            guard isCapturingSignOutCredentials else {
                continuation.resume()
                return
            }
            signOutCredentialCaptureWaiters.append(continuation)
        }
    }

    func finishSignOutCredentialCapture() {
        guard isCapturingSignOutCredentials || !signOutCredentialCaptureWaiters.isEmpty else {
            return
        }
        isCapturingSignOutCredentials = false
        let waiters = signOutCredentialCaptureWaiters
        signOutCredentialCaptureWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
