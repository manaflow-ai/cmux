import Foundation

extension CloudMachineLink {
    /// Waits for the link client's stderr reader to reach EOF, so an exit error
    /// reads its last lines: they can still be in flight when the process
    /// exits. A child the client started can hold the pipe open, so the wait
    /// is bounded.
    nonisolated static func awaitStderrDrain(_ drain: Task<Void, Never>, upTo limit: Duration = .seconds(1)) async {
        let drained = CloudLinkFirstValue<Bool>()
        Task.detached {
            await drain.value
            drained.resolve(true)
        }
        Task.detached {
            try? await Task.sleep(for: limit)
            drained.resolve(false)
        }
        _ = await drained.result
    }

    private func linkProcessDidExit(_ exitedProcess: Process, status: Int32, attemptID: UUID) async {
        guard process === exitedProcess, linkAttemptID == attemptID else { return }
        let stderrDrain = self.stderrDrain
        self.stderrDrain = nil
        eventsSubscriptionID = nil
        eventsReaderTask?.cancel()
        eventsReaderTask = nil
        eventsRecoveryTask?.cancel()
        eventsRecoveryTask = nil
        cancelEventsStabilityReset()
        eventsRecoveryPhase = .healthy
        await cancelEventsStream()
        process = nil
        processExit = nil
        connected = nil
        if state != .unavailable {
            state = status == 0 ? .unavailable : .error
            lastError = status == 0 ? nil : LinkError.exited(status: status, output: stderrTail.joined(separator: "\n")).errorDescription
        }
        await resourceConnection?.close()
        resourceConnection = nil
        changesContinuation.yield(.streamEnded(reason: "link_exit", cursor: nil))
        changesContinuation.finish()
        await releaseHubLeaseOnce()
        if let stderrDrain, status != 0 {
            Task { [weak self] in
                await Self.awaitStderrDrain(stderrDrain)
                await self?.refineExitError(status: status, attemptID: attemptID)
            }
        }
    }

    private func refineExitError(status: Int32, attemptID: UUID) {
        guard status != 0, state == .error, process == nil, linkAttemptID == attemptID else { return }
        lastError = LinkError.exited(status: status, output: stderrTail.joined(separator: "\n")).errorDescription
    }
}
