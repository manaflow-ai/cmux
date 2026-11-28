public import CmuxNextDaemon
public import CmuxNextWakeups
import Foundation
import os

/// Serves the `credential` provider family on the local daemon connection
/// (cx-wb5.63): registers after each handshake where the daemon said this
/// is the verified cmux app (`client-hello` `user_origin_allowed`, the same
/// claim the daemon checks on `apps-provider-register`), and answers every
/// `apps-provider-request` of the family through ``CloudCredentialRelay``
/// on the connection that sent it. A non-verified connection never
/// registers, so no credential call reaches it.
@MainActor
public final class CloudCredentialProvider {
    public typealias Register = @Sendable (AppsProviderRegisterRequest) async throws -> JSONValue
    public typealias Reply = @Sendable (AppsProviderResultRequest) async throws -> Void

    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.relay")
    private let relay: CloudCredentialRelay
    /// One task per call in flight, by request id; a cancel ends it.
    private var running: [UInt64: Task<Void, Never>] = [:]

    public init(relay: CloudCredentialRelay) {
        self.relay = relay
    }

    /// Calls in flight (tests).
    var inFlight: Int { running.count }

    /// Spacing of registration retries: 0.5 s doubling, at most 30 s, jittered (as `AppsProviderChannel`).
    public nonisolated static let registerBackoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))

    /// Registers the family when `userOriginAllowed`; returns whether it is
    /// registered. A transient failure (the connection not up yet or gone, as
    /// in a launch's daemon handoff, a timeout, or the old connection still
    /// holding the family) is tried again with `backoff` until it lands or
    /// the task is cancelled (the caller cancels it when the connection
    /// changes, https://github.com/manaflow-ai/cmux/issues/65793). A refusal
    /// is logged and not retried on this connection.
    public static func register(userOriginAllowed: Bool, backoff: Backoff = registerBackoff, send: Register) async -> Bool {
        guard userOriginAllowed else {
            logger.info("credential provider: not the verified app connection; not registered")
            return false
        }
        var backoff = backoff
        // wakeup-allow: a retry after a failed registration, never a poll: each pass awaits the request, then Backoff.wait (throws once cancelled).
        while true {
            do {
                _ = try await send(AppsProviderRegisterRequest(families: [CloudCredentialRelay.family]))
                if backoff.attempt > 0 { logger.info("credential provider: registered after \(backoff.attempt, privacy: .public) retries") }
                return true
            } catch {
                guard isTransient(error) else {
                    logger.error("credential provider: register refused: \(String(describing: error), privacy: .public)")
                    return false
                }
                logger.info("credential provider: register failed: \(String(describing: error), privacy: .public); retry \(backoff.attempt + 1) after backoff")
                // concurrency-allow: Backoff.wait is an async sleep after a failed registration, not a blocking wait.
                do { try await backoff.wait(owner: "CloudCredentialProvider.register") } catch { return false }
            }
        }
    }

    /// A registration failure that another try on the same connection can fix (the codes `AppsProviderChannel`
    /// tries again, and any refusal the daemon marks retryable).
    nonisolated static func isTransient(_ error: any Error) -> Bool {
        switch error as? DaemonError {
        case .notConnected?, .connectionClosed?, .daemonShutdown?, .timedOut?: true
        case .command(_, _, let code, _, let retryable)?: retryable == true || ["apps.provider.taken", "failed", "not_connected", "timeout"].contains(code)
        default: false
        }
    }

    /// Handles one local daemon event: a provider call of the family starts
    /// its answer, a cancel stops it. Other events are ignored.
    public func handle(_ event: DaemonEvent, reply: @escaping Reply) {
        if let cancel = AppsProviderCancel(event) {
            running.removeValue(forKey: cancel.requestID)?.cancel()
            return
        }
        guard let call = AppsProviderCall(event),
              call.op.hasPrefix(CloudCredentialRelay.family + ".") else { return }
        let relay = relay
        let id = call.requestID
        // task-owner: running[id]; removed when it answers, cancelled by apps-provider-cancel or stop()
        running[id] = Task { [weak self] in
            let answer = await relay.answer(call)
            if !Task.isCancelled {
                do {
                    try await reply(AppsProviderResultRequest(requestID: id, ok: answer.ok, body: answer.body))
                } catch {
                    Self.logger.error("credential provider: result \(id) not sent: \(String(describing: error), privacy: .public)")
                }
            }
            self?.running[id] = nil
        }
    }

    /// Cloud turned off or back on by an organization's policy (``CloudCredentialRelay/policy``):
    /// turned off, every call in flight ends and later ones are refused.
    public func setTurnedOff(_ turnedOff: Bool) {
        relay.policy.set(turnedOff: turnedOff)
        if turnedOff { stop() }
    }

    /// Ends every call in flight (sign-out, quit, connection gone).
    public func stop() {
        for task in running.values { task.cancel() }
        running.removeAll()
    }
}
