internal import Foundation

// Resolution of the bootstrap terminal's remote TTY name (written by the
// relay shell hook to `~/.cmux/relay/<port>.tty`), with a bounded retry.
// Faithful lift; the legacy retry `asyncAfter` work item became an
// injected-clock task with a token guard. The 0.5s delay and 8-retry limit
// are identical.
extension RemoteSessionCoordinator {
    static let bootstrapRemoteTTYRetryDelay: TimeInterval = 0.5
    static let bootstrapRemoteTTYRetryLimit = 8

    func requestBootstrapRemoteTTYIfNeededLocked() {
        // The bootstrap TTY is resolved only to TTY-scope the port scans, so
        // when port scanning is disabled there is no reason to spawn ssh for
        // it (issue #6123). Re-enabling re-requests it.
        guard remotePortScanningEnabled else { return }
        guard !bootstrapRemoteTTYResolved else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0 else { return }
        if !remotePortScanTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = true
            cancelBootstrapRemoteTTYRetryLocked()
            bootstrapRemoteTTYRetryCount = 0
            return
        }
        guard !bootstrapRemoteTTYFetchInFlight else { return }
        bootstrapRemoteTTYFetchInFlight = true
        defer { bootstrapRemoteTTYFetchInFlight = false }

        let command = "sh -c \("tty_path=\"$HOME/.cmux/relay/\(relayPort).tty\"; if [ -r \"$tty_path\" ]; then cat \"$tty_path\"; fi".shellSingleQuoted)"
        do {
            let result = try sshExec(
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
                timeout: 2
            )
            guard result.status == 0 else {
                scheduleBootstrapRemoteTTYRetryLocked()
                return
            }
            guard let ttyName = Self.normalizedRemotePortScanTTYName(result.stdout) else {
                scheduleBootstrapRemoteTTYRetryLocked()
                return
            }
            bootstrapRemoteTTYResolved = true
            cancelBootstrapRemoteTTYRetryLocked()
            bootstrapRemoteTTYRetryCount = 0
            debugLog("remote.tty.bootstrap.ready tty=\(ttyName) \(debugConfigSummary())")
            publishBootstrapRemoteTTY(ttyName)
        } catch {
            debugLog("remote.tty.bootstrap.failed error=\(error.localizedDescription) \(debugConfigSummary())")
            scheduleBootstrapRemoteTTYRetryLocked()
        }
    }

    func scheduleBootstrapRemoteTTYRetryLocked() {
        guard !isStopping else { return }
        guard remotePortScanningEnabled else { return }
        guard daemonReady else { return }
        guard !bootstrapRemoteTTYResolved else { return }
        guard remotePortScanTTYNames.isEmpty else { return }
        guard bootstrapRemoteTTYRetryCount < Self.bootstrapRemoteTTYRetryLimit else { return }
        guard bootstrapRemoteTTYRetryToken == nil else { return }

        bootstrapRemoteTTYRetryCount += 1
        // Whole-second-fraction legacy delay converts exactly; round up so
        // the delay can never undershoot the legacy deadline.
        let milliseconds = Int((Self.bootstrapRemoteTTYRetryDelay * 1000).rounded(.up))
        let token = UUID()
        bootstrapRemoteTTYRetryToken = token
        // Cancellation is absorbed by guards, not checks: a cancelled sleep
        // throws (no wakeup), and a stale post-sleep wakeup fails the token
        // guard because every cancel path clears the token first.
        bootstrapRemoteTTYRetryTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.clock.sleep(forMilliseconds: milliseconds)) != nil else { return }
            self.queue.async {
                self.bootstrapRemoteTTYRetryDelayElapsed(token: token)
            }
        }
    }

    /// Runs on `queue` after the TTY-retry delay; the token guard drops
    /// stale wakeups from cancelled retries.
    private func bootstrapRemoteTTYRetryDelayElapsed(token: UUID) {
        guard bootstrapRemoteTTYRetryToken == token else { return }
        bootstrapRemoteTTYRetryTask = nil
        bootstrapRemoteTTYRetryToken = nil
        requestBootstrapRemoteTTYIfNeededLocked()
    }

    func cancelBootstrapRemoteTTYRetryLocked() {
        bootstrapRemoteTTYRetryTask?.cancel()
        bootstrapRemoteTTYRetryTask = nil
        bootstrapRemoteTTYRetryToken = nil
    }
}
