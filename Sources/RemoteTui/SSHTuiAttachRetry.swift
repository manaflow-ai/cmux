import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// How a restored or reconnecting `cmux ssh` workspace retries its attach.
///
/// After a relaunch the first attach often runs before the network is ready
/// (Tailscale, DNS or Wi-Fi still coming up). One failure there is not a
/// workspace failure, so a retryable error keeps the workspace `.connecting`
/// and retries after a short backoff. Only an error that retrying cannot fix,
/// or a run of failures that outlasts the backoff schedule, reaches the sidebar.
struct SSHTuiAttachRetryPolicy: Sendable {
    /// Delay before each retry; the attach reports its error once these run out.
    let delays: [Duration]
    /// Cadence of the quiet retries that follow a reported, retryable error.
    var reportedFailureRetryInterval: Duration = .seconds(30)

    static let standard = SSHTuiAttachRetryPolicy(
        delays: [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15)]
    )

    /// The delay before the next attempt after `failureCount` consecutive
    /// failures ending in `error`, or nil when the attach should report it.
    func retryDelay(afterFailure failureCount: Int, error: Error) -> Duration? {
        guard Self.isRetryable(error), failureCount >= 1, failureCount <= delays.count else { return nil }
        return delays[failureCount - 1]
    }

    /// Errors worth another attempt while the workspace is still connecting.
    static func isRetryable(_ error: Error) -> Bool {
        if isPermanent(error) { return false }
        // The carrier already waited out its own connect deadline (minutes,
        // with internal retries); another fast lap only delays the report.
        if case CloudMachineLink.LinkError.timedOut? = error as? CloudMachineLink.LinkError { return false }
        return true
    }

    /// Errors that no later attempt can fix, so a reported failure stops
    /// retrying in the background and waits for Reconnect or a link-up.
    static func isPermanent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let failure = error as? CloudDiagnosticFailure, failure == .unsupported { return true }
        if case CloudMachineLink.LinkError.clientMissing? = error as? CloudMachineLink.LinkError { return true }
        return CloudMachineAccessLoss(error: error) != nil
    }

    /// Whether a waiting or failed attach should retry now instead of
    /// waiting out its backoff. The provider's terminal mirrors keep
    /// reconnecting the carrier on their own; once the machine link reports
    /// connected, the workspace attach should follow immediately. A link that
    /// was already connected when the attach failed does not trigger this, so
    /// an attach that fails for another reason cannot spin on every catalog change.
    static func shouldRetryNow(linkWasConnectedAtFailure: Bool, linkState: SurfaceLinkState?) -> Bool {
        !linkWasConnectedAtFailure && linkState == .connected
    }
}

/// A backoff wait that a link-up event can end early.
@MainActor
final class SSHTuiAttachBackoff {
    private var sleeper: Task<Void, Never>?
    /// A wake that arrived before the wait began ends that wait at once.
    private var wakeRequested = false

    /// Waits `delay` on `clock`, or until `wake()`, or until the caller's task is cancelled.
    func wait(_ delay: Duration, clock: any Clock<Duration>) async {
        if wakeRequested {
            wakeRequested = false
            return
        }
        let sleeper = Task { _ = try? await clock.sleep(for: delay) }
        self.sleeper = sleeper
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        if self.sleeper == sleeper { self.sleeper = nil }
    }

    func wake() {
        if let sleeper {
            sleeper.cancel()
        } else {
            wakeRequested = true
        }
    }
}

/// Runs one attach with bounded retries. Kept separate from the coordinator
/// so the state transitions can be tested without an SSH carrier.
enum SSHTuiAttachRetry {
    enum Outcome {
        case connected
        case failed(Error)
        case cancelled
    }

    /// Calls `attempt` until it succeeds, is cancelled, or `policy` gives up.
    ///
    /// `attempt` receives a predicate telling it whether a given error will be
    /// retried, so it can keep a reserved pane pending instead of failing it
    /// between attempts. `failed` runs before each backoff wait so the caller
    /// can record whether the machine link was up when the attempt failed,
    /// and `retrying` runs when that wait ends, before the next attempt.
    @MainActor
    static func run(
        policy: SSHTuiAttachRetryPolicy,
        clock: any Clock<Duration>,
        backoff: SSHTuiAttachBackoff,
        failed: @MainActor (Error) -> Void = { _ in },
        retrying: @MainActor () -> Void = {},
        attempt: @MainActor (_ willRetry: (Error) -> Bool) async throws -> Void
    ) async -> Outcome {
        var failures = 0
        while true {
            if Task.isCancelled { return .cancelled }
            let nextFailureCount = failures + 1
            do {
                try await attempt { policy.retryDelay(afterFailure: nextFailureCount, error: $0) != nil }
                return .connected
            } catch is CancellationError {
                return .cancelled
            } catch {
                if Task.isCancelled { return .cancelled }
                failures = nextFailureCount
                guard let delay = policy.retryDelay(afterFailure: failures, error: error) else {
                    return .failed(error)
                }
                failed(error)
                await backoff.wait(delay, clock: clock)
                retrying()
            }
        }
    }
}
