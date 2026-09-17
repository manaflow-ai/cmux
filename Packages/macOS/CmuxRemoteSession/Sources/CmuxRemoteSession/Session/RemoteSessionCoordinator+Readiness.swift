internal import CmuxCore
internal import Foundation

// The readiness state machine's terminal transition and the deadline that
// guarantees it is reached (https://github.com/manaflow-ai/cmux/issues/12813).
//
// A session seeks readiness: daemon hello, then reverse relay, then a
// published proxy endpoint. The bootstrap and reachability policies already
// bound the phases that can fail outright. The relay restart loop and the
// escalate-and-rebootstrap cycle are retry loops with no terminal transition
// of their own, so a relay or proxy that can never come up used to leave the
// session "reconnecting" forever while every `ssh-pty-attach --wait` parked on
// it timed out and retried. The deadline gives those phases a verdict too, and
// parking hands that verdict to the waiters.
extension RemoteSessionCoordinator {
    /// Longest a session may spend between its first daemon hello and a
    /// published proxy endpoint before it parks. A healthy host gets there in
    /// seconds; daemon uploads happen before the hello and do not count.
    static let readinessDeadlineMilliseconds = 60_000

    /// Whether automatic reconnect is halted until an explicit re-arm.
    var reconnectSuspended: Bool { parkedState != nil }

    /// Parks the session: the single terminal transition of the readiness
    /// state machine.
    ///
    /// Stops the retry owners, publishes the suspended state, and releases
    /// every PTY bridge start parked on readiness with the same `detail`, so
    /// the terminal shows what the sidebar shows instead of waiting out its
    /// timeout against a session that gave up.
    func parkSessionLocked(
        cause: RemoteSessionParkedState.Cause,
        daemonState: WorkspaceRemoteDaemonState,
        detail: String
    ) {
        guard !isStopping else { return }
        cancelReconnectRetryLocked()
        cancelReadinessDeadlineLocked()
        parkedState = RemoteSessionParkedState(cause: cause, detail: detail)
        publishDaemonStatus(daemonState, detail: detail)
        publishState(.suspended, detail: detail)
        failPendingPTYBridgeStartsLocked(error: RemoteSessionParkedError(detail: detail))
    }

    /// Ends the current readiness seek: the session became ready, stopped, or
    /// was re-armed, so neither a parked verdict nor its deadline applies.
    func endReadinessSeekLocked() {
        parkedState = nil
        cancelReadinessDeadlineLocked()
    }

    /// Arms the deadline once per readiness seek, at the first daemon hello.
    ///
    /// Later hellos within the same seek do not re-arm it: a session that
    /// keeps bootstrapping successfully and then losing its relay or proxy is
    /// exactly the loop this bounds. A bounded, cancellable deadline is the
    /// intended behavior here, driven by the injected clock so tests advance
    /// it; the token guard drops a wakeup from a cancelled or consumed arm.
    func armReadinessDeadlineLocked() {
        guard !isStopping, proxyConnectionDesired, readinessDeadlineToken == nil else { return }
        let token = UUID()
        readinessDeadlineToken = token
        readinessDeadlineTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.clock.sleep(
                forMilliseconds: Self.readinessDeadlineMilliseconds
            )) != nil else { return }
            self.queue.async {
                self.readinessDeadlineElapsed(token: token)
            }
        }
    }

    func cancelReadinessDeadlineLocked() {
        readinessDeadlineTask?.cancel()
        readinessDeadlineTask = nil
        readinessDeadlineToken = nil
    }

    private func readinessDeadlineElapsed(token: UUID) {
        guard readinessDeadlineToken == token else { return }
        readinessDeadlineTask = nil
        readinessDeadlineToken = nil
        guard !isStopping, !isSystemSleeping, !canStartPTYBridgeLocked else { return }

        // Between an escalated proxy failure and the next hello the daemon is
        // down and the relay flag is reset with it; that is the proxy/daemon
        // transport cycling, not the relay failing to start.
        let relayIsBlocking = daemonReady && configuration.relayPort != nil && !reverseRelayReady
        let detail: String
        if relayIsBlocking {
            detail = String(
                format: String(
                    localized: "remoteSession.parked.relayNotReady",
                    defaultValue: "The cmux relay on %@ did not become ready (the host may not allow SSH remote port forwarding). Automatic reconnect paused; use Reconnect to try again."
                ),
                configuration.displayTarget
            )
        } else {
            detail = String(
                format: String(
                    localized: "remoteSession.parked.proxyNotReady",
                    defaultValue: "The cmux proxy tunnel to %@ did not become ready. Automatic reconnect paused; use Reconnect to try again."
                ),
                configuration.displayTarget
            )
        }
        debugLog(
            "remote.session.readiness.timedOut phase=\(relayIsBlocking ? "relay" : "proxy") " +
                "daemonReady=\(daemonReady ? 1 : 0) \(debugConfigSummary())"
        )
        // A parked session owns no running transport: end the relay restart
        // loop and drop the proxy lease so its broker stops redialing.
        resetTransportForReconnectLocked()
        parkSessionLocked(cause: .readinessTimedOut, daemonState: .error, detail: detail)
    }
}
