internal import CmuxMobileShellModel
internal import Foundation

@MainActor
extension MobileShellComposite {
    /// Parks a composer send while connection recovery has retired the dead
    /// client and is dialing its replacement. Returns once a client is
    /// installed, recovery stops (success, failure, or cancellation), or the
    /// reconnect-attempt deadline elapses; the caller re-reads `remoteClient`
    /// and fails the send if it is still absent. A send with no recovery in
    /// flight (signed out, Mac forgotten, plain disconnect) returns at once,
    /// as does one for a locally served or external-host terminal.
    func awaitRemoteClientDuringConnectionRecovery(
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard composerSendWaitsForRecovery(terminalID: terminalID) else { return }
        let nanoseconds = runtime?.reconnectAttemptDeadlineNanoseconds
            ?? 30_000_000_000
        let deadline = ContinuousClock.now + .nanoseconds(Int64(clamping: nanoseconds))
        let timeout = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
            self?.resumeComposerSendClientWaiters()
        }
        defer { timeout.cancel() }
        while composerSendWaitsForRecovery(terminalID: terminalID),
              ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                composerSendClientWaiters.append(continuation)
            }
        }
    }

    private func composerSendWaitsForRecovery(
        terminalID: MobileTerminalPreview.ID
    ) -> Bool {
        remoteClient == nil
            && isRecoveringConnection
            && !locallyServedOwnsSurface(terminalID.rawValue)
            && !externalHostOwnsSurface(terminalID.rawValue)
    }

    func resumeComposerSendClientWaiters() {
        let waiters = composerSendClientWaiters
        composerSendClientWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
