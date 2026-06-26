import Foundation
import Observation

/// Reconnect-backoff sub-model for one `tmux -CC` control connection.
///
/// Owns the single sleeping `Task` between reconnect attempts and the attempt
/// counter that drives the capped exponential backoff. Drives its owning connection
/// through ``RemoteTmuxReconnectHost`` (a `.reconnecting` phase check, a respawn
/// trigger, and a diagnostics event string), so the connection-state machine, the
/// `%exit` notification, and the actual ssh respawn stay app-side while only the
/// backoff schedule lives here.
@MainActor
@Observable
public final class RemoteTmuxReconnectController {
    @ObservationIgnored
    private weak var host: (any RemoteTmuxReconnectHost)?

    /// The current reconnect backoff task (a single sleeping `Task` between
    /// attempts); cancelled on `stop()` / genuine end so a dead connection stops
    /// retrying.
    @ObservationIgnored
    private var reconnectTask: Task<Void, Never>?

    /// Number of reconnect attempts since the last successful connect, driving the
    /// capped exponential backoff. Reset to 0 on a successful connect.
    public private(set) var reconnectAttemptCount = 0

    /// Base reconnect backoff (seconds); doubled each attempt up to ``reconnectMaxDelaySeconds``.
    private static let reconnectBaseDelaySeconds: Double = 1
    /// Cap on the reconnect backoff (seconds). Retries continue indefinitely at this
    /// interval until the network returns or the session is found to be gone.
    private static let reconnectMaxDelaySeconds: Double = 10

    public init() {}

    /// Injects the owning connection as the phase/respawn/diagnostics seam. Call once
    /// right after the connection constructs the controller.
    public func attach(host: any RemoteTmuxReconnectHost) {
        self.host = host
    }

    /// Resets the attempt counter to 0 at the start of a fresh reconnect sequence
    /// (a transport loss), before the first ``scheduleAttempt()`` of that sequence.
    public func resetAttempts() {
        reconnectAttemptCount = 0
    }

    /// Cancels the in-flight backoff task without touching the attempt counter.
    /// Shared by deliberate teardown (``RemoteTmuxControlConnection/stop()``) and a
    /// session-gone reconnect classification, so a dead connection stops retrying.
    public func cancel() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Records a successful connect (`%enter`): resets the attempt counter and
    /// cancels any pending retry so the next outage starts a fresh backoff walk.
    public func handleConnected() {
        reconnectAttemptCount = 0
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Schedules the next reconnect attempt after a capped exponential backoff.
    public func scheduleAttempt() {
        guard let host else { return }
        let attempt = reconnectAttemptCount
        reconnectAttemptCount += 1
        let delay = min(
            Self.reconnectMaxDelaySeconds,
            Self.reconnectBaseDelaySeconds * pow(2, Double(attempt))
        )
        host.recordReconnectEvent("reconnect-scheduled attempt=\(attempt) delay=\(delay)")
        reconnectTask?.cancel()
        // A bounded, cancellable backoff before the next attempt (not a poll/settle):
        // cancelled by stop()/genuine end, re-armed by each failed attempt. `do/catch`
        // (not `try?`) so a cancelled sleep returns immediately — the previously
        // scheduled task can't fall through and double-spawn a second ssh client.
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, let host = self.host, host.isReconnecting else { return }
            host.performReconnectAttempt()
        }
    }
}
