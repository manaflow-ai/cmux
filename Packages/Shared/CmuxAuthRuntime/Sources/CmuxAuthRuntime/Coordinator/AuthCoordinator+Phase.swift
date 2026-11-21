import Foundation

/// The reducer's answer to a phase start request.
enum AuthPhaseStart {
    case started(UInt64)
    case refused
}

@MainActor
extension AuthCoordinator {
    /// Runs one phase as a coordinator-owned task raced against its deadline.
    ///
    /// The reducer decides whether the phase may start (a timed-out run still
    /// parked refuses retries), what a timeout or caller cancellation parks,
    /// which runs a sign-out cancels or a sign-in joins, and whether a result
    /// that outlived a sign-out stands. This runner only does the I/O those
    /// answers name. The losing side is not joined: some SDK calls ignore
    /// cancellation, and joining them would keep spinners alive past the
    /// deadline. A result that loses the race goes to `discardLate`.
    func runPhase<T: Sendable>(
        _ phase: AuthPhase,
        timeout: Duration,
        deadline: AuthTokenDeadline? = nil,
        discardLate: (@MainActor @Sendable (T) async -> Void)? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let deadline = deadline ?? clock.authTokenDeadline(after: timeout)
        guard !deadline.hasExpired() else { throw AuthError.timedOut }
        phaseStart = nil
        feed(["phaseStartRequested": ["phase": .string(phase.rawValue), "nowNanos": AuthWire(Self.uptimeNanos)]])
        let start = phaseStart
        phaseStart = nil
        if case .refused = start {
            log.log("auth.phase=\(phase.rawValue) previous timed-out operation still active")
            throw AuthError.timedOut
        }
        // No answer (a refused reducer event): run the work untracked.
        let id: UInt64? = if case .started(let runID) = start { runID } else { nil }
        let work = Task {
            let result: Result<T, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            if let id { try await settlePhase(id) }
            let value = try result.get()
            // Finished, but too late for its caller: the result is discarded.
            if Task.isCancelled || deadline.hasExpired() {
                await discardLate?(value)
                throw Task.isCancelled ? CancellationError() : AuthError.timedOut
            }
            return value
        }
        let ended = id.map { track(work, id: $0) }

        return try await withTaskCancellationHandler {
            try await race(work, ended: ended, phase: phase, id: id, timeout: timeout, deadline: deadline, discardLate: discardLate)
        } onCancel: {
            work.cancel()
            guard let id else { return }
            Task { @MainActor in
                self.feed(["phaseCallerCancelled": ["id": AuthWire(id), "nowNanos": AuthWire(Self.uptimeNanos)]])
            }
        }
    }

    private static var uptimeNanos: UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Tracks a run until it ends. The returned task finishes once the
    /// reducer has heard the run ended, so a caller (or a join) that resumes
    /// after it can start the next run of the phase.
    private func track<T>(_ work: Task<T, any Error>, id: UInt64) -> Task<Void, Never> {
        let completion = Task {
            _ = await work.result
            phaseWork[id] = nil
            feed(["phaseEnded": ["id": AuthWire(id)]])
        }
        phaseWork[id] = AuthTrackedTokenWork(cancel: { work.cancel() }, completion: completion)
        return completion
    }

    private func race<T: Sendable>(
        _ work: Task<T, any Error>,
        ended: Task<Void, Never>?,
        phase: AuthPhase,
        id: UInt64?,
        timeout: Duration,
        deadline: AuthTokenDeadline,
        discardLate: (@MainActor @Sendable (T) async -> Void)?
    ) async throws -> T {
        try Task.checkCancellation()
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncThrowingStream<T, any Error> { continuation in
            let waiter = Task {
                let result = await work.result
                await ended?.value
                guard await race.winOperation() else {
                    if case .success(let value) = result { await discardLate?(value) }
                    return
                }
                switch result {
                case .success(let value):
                    continuation.yield(value)
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
            let timer = Task { [log] in
                do {
                    try await deadline.wait()
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard await race.winTimeout() else { return }
                log.log("auth.phase=\(phase.rawValue) timed out after \(timeout)")
                if let id {
                    await MainActor.run {
                        self.feed(["phaseTimedOut": ["id": AuthWire(id), "nowNanos": AuthWire(Self.uptimeNanos)]])
                    }
                }
                work.cancel()
                continuation.finish(throwing: AuthError.timedOut)
            }
            continuation.onTermination = { _ in
                waiter.cancel()
                timer.cancel()
            }
        }
        for try await value in stream {
            return value
        }
        if Task.isCancelled { throw CancellationError() }
        throw AuthError.timedOut
    }

    /// Asks the reducer whether a finished run's result stands, doing the
    /// waits and reads it asks for when a sign-out raced the run.
    private func settlePhase(_ id: UInt64) async throws {
        var step = phaseStep(id, ["phaseOperationFinished": ["id": AuthWire(id)]])
        while true {
            switch step {
            case "phaseResultDropped":
                throw CancellationError()
            case "awaitSignOutCapture":
                await waitForSignOutCredentialCapture()
                step = phaseStep(id, ["phaseSignOutCaptureAwaited": ["id": AuthWire(id)]])
            case "compareStaleRefreshToken":
                var cleared = false
                if let token = await client.refreshToken(), token != latestSignInRefreshToken {
                    await client.clearLocalSession(ifRefreshTokenMatches: token)
                    cleared = await client.refreshToken() == nil
                }
                step = phaseStep(id, ["phaseStaleRefreshTokenCompared": ["id": AuthWire(id), "cleared": .bool(cleared)]])
            default:
                return
            }
        }
    }

    private func phaseStep(_ id: UInt64, _ event: AuthWire) -> String? {
        phaseSteps[id] = nil
        feed(event)
        return phaseSteps.removeValue(forKey: id)
    }

    /// Cancels the named runs and waits for them to finish, up to `timeout`.
    /// - Returns: Whether every run finished in time.
    func cancelAndJoinPhaseWork(_ ids: [UInt64], within timeout: Duration) async -> Bool {
        let work = ids.compactMap { phaseWork[$0] }
        for run in work { run.cancel() }
        let completions = work.map(\.completion)
        guard !completions.isEmpty else { return true }
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncStream<Bool> { continuation in
            let join = Task {
                for completion in completions { await completion.value }
                guard await race.winOperation() else { return }
                continuation.yield(true)
                continuation.finish()
            }
            let timer = Task { [clock] in
                do { try await clock.sleep(for: timeout, tolerance: nil) } catch { return }
                guard await race.winTimeout() else { return }
                continuation.yield(false)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                join.cancel()
                timer.cancel()
            }
        }
        for await joined in stream { return joined }
        return false
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
