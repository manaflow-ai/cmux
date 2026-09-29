import CMUXMobileCore
import Foundation

extension IrxPeerEngine {
    /// Joins this peer's dial. Cancelling the last waiter retires that exact
    /// attempt, including its native cancellation handle, before permitting a retry.
    public func ensureSession(explicit: Bool = false, trigger: String) async throws -> IrxClientSession {
        try Task.checkCancellation()
        hasConnectionIntent = true
        if let current = session, !explicit, await !connectionIsClosed(current.connection),
           session?.connection === current.connection {
            try Task.checkCancellation()
            return current
        }
        guard applicationActive else { throw CancellationError() }
        if let parkedCode, !explicit {
            throw IrxAdmissionDenied(code: IrxCloseCode(rawValue: parkedCode) ?? .invalidGrant)
        }
        if explicit, let cooldownUntil, clockNow() < cooldownUntil,
           (lastDialError as? any CmxRetryAfterProviding)?.retryAfterSeconds != nil {
            throw lastDialError ?? IrxConnectionError.closed(nil)
        }
        if explicit {
            let previous = session
            session = nil
            terminationWatcher?.cancel()
            terminationWatcher = nil
            parkedCode = nil
            cooldownUntil = nil
            invalidateDial()
            if let previous {
                Task { await previous.connection.close(code: .explicitRedial, origin: .local) }
            }
        }
        if dialTask == nil, !explicit, let cooldownUntil, clockNow() < cooldownUntil {
            throw lastDialError ?? IrxConnectionError.closed(nil)
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                dialWaiters[waiterID] = continuation
                if dialTask == nil {
                    startDial(trigger: trigger)
                } else {
                    record("dial-joined", ["trigger": trigger])
                }
            }
        } onCancel: {
            Task { await self.cancelDialWaiter(waiterID) }
        }
    }

    private func startDial(trigger: String) {
        redialTimer?.cancel()
        redialTimer = nil
        setState(.connecting)
        record("dial-started", ["trigger": trigger])
        dialGeneration &+= 1
        let generation = dialGeneration
        let task = Task { [dialOnce] in
            try Task.checkCancellation()
            return try await dialOnce()
        }
        dialTask = task
        // Neither the waiter nor the deadline awaits native cleanup. A late
        // result belongs only to this generation and is closed on arrival.
        Task { [weak self] in
            let result = await task.result
            guard let self else {
                if case let .success(late) = result {
                    await late.connection.close(code: .explicitRedial, origin: .local)
                }
                return
            }
            await self.finishDial(result, generation: generation, trigger: trigger)
        }
        dialDeadlineTask = Task { [weak self, dialClock, limit = config.dialDeadline] in
            do { try await dialClock.sleep(for: limit) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.expireDial(generation: generation, trigger: trigger)
        }
    }

    private func expireDial(generation: UInt64, trigger: String) {
        guard dialGeneration == generation, let outstanding = dialTask else { return }
        finishDial(.failure(IrxDialTimedOut()), generation: generation, trigger: trigger)
        outstanding.cancel()
    }

    private func finishDial(
        _ result: Result<IrxClientSession, any Error>,
        generation: UInt64,
        trigger: String
    ) {
        guard dialGeneration == generation, dialTask != nil else {
            if case let .success(late) = result {
                Task { await late.connection.close(code: .explicitRedial, origin: .local) }
            }
            return
        }
        dialTask = nil
        dialDeadlineTask?.cancel()
        dialDeadlineTask = nil
        let waiters = dialWaiters.values
        dialWaiters = [:]
        switch result {
        case .success(let established):
            adopt(established)
        case .failure(let error):
            if let denial = error as? IrxAdmissionDenied, denial.code != .admissionTimeout {
                parkedCode = denial.code.rawValue
                setState(.closed(code: denial.code.rawValue))
                record("dial-denied", ["code": denial.code.rawValue])
            } else if error is CancellationError {
                setState(.idle)
                record("dial-cancelled", ["trigger": trigger])
            } else {
                lastDialError = error
                setState(.closed(code: "dial-failed"))
                record("dial-failed", ["trigger": trigger, "error": String(describing: error)])
                scheduleRedial(error: error)
            }
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func cancelDialWaiter(_ id: UUID) {
        guard let waiter = dialWaiters.removeValue(forKey: id) else { return }
        if dialWaiters.isEmpty {
            invalidateDial()
            setState(.idle)
        }
        waiter.resume(throwing: CancellationError())
    }

    func invalidateDial() {
        dialGeneration &+= 1
        if dialTask != nil { record("dial-cancelled") }
        dialTask?.cancel()
        dialTask = nil
        dialDeadlineTask?.cancel()
        dialDeadlineTask = nil
        let waiters = dialWaiters.values
        dialWaiters = [:]
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }
}
