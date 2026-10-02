internal import Foundation

extension RemoteSessionCoordinator {
    /// Queues one complete blocking connection attempt through the per-host broker.
    func requestConnectionAttemptLocked() {
        guard !isStopping, connectionAttemptTask == nil else { return }
        let token = UUID()
        let configuration = self.configuration
        let connectionBroker = self.connectionBroker
        connectionAttemptToken = token
        connectionAttemptTask = Task { [weak self] in
            do {
                try await connectionBroker.withConnectionAttempt(for: configuration) { [weak self] in
                    guard let self else { return }
                    await self.performConnectionAttemptOnQueue(token: token)
                }
            } catch is CancellationError {
                // Stop/reconfiguration cancels queued permits and owns state publication.
            } catch {
                // The operation itself is nonthrowing; no other error is expected.
            }
            self?.clearConnectionAttemptTask(token: token)
        }
    }

    /// Runs the queue-confined legacy attempt while the async broker permit is held.
    private func performConnectionAttemptOnQueue(token: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }
                guard connectionAttemptToken == token, !isStopping else { return }
                connectionAttemptTask = nil
                connectionAttemptToken = nil
                beginConnectionAttemptLocked()
            }
        }
    }

    /// Clears a cancelled or rejected request without disturbing a replacement token.
    private func clearConnectionAttemptTask(token: UUID) {
        queue.async { [weak self] in
            guard let self, self.connectionAttemptToken == token else { return }
            self.connectionAttemptTask = nil
            self.connectionAttemptToken = nil
        }
    }

    /// Cancels a queued permit; an already-running queue attempt finishes synchronously.
    func cancelConnectionAttemptLocked() {
        connectionAttemptToken = nil
        connectionAttemptTask?.cancel()
        connectionAttemptTask = nil
    }
}
