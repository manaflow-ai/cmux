import CmuxNextAgentPane
package import CmuxNextCompat
package import CmuxNextWakeups
package import Foundation
package import os
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Gives the local model relay (cmux-tui crate cmux-coderouter, started by
/// the acpmux daemon) the signed-in account's bearer for the hosted cmux
/// model router, and takes it back on sign-out (plans/cmux-next/model-router.md,
/// cx-dna4.4). The relay holds the bearer in memory only; agents reach the
/// router through the relay with its own per-session keys, never with this
/// token. The lease renews shortly before the token expires.
///
/// Each pass waits on one one-shot ``DemandTimer`` (``Wake``): the renewal is a flexible deadline at the
/// token's expiry minus ``renewMargin`` that may come early but never late, a retry after a failure one
/// that never comes early. With a valid token nothing else wakes the lease.
@MainActor package final class ModelRouterLease {
    private let tokens: any CloudLeaseTokens
    private let apiBaseURL: URL
    private let relay: ModelRouterRelay
    private let clock: any Clock<Duration>
    /// Now on the wall clock, where the token's `exp` lives (tests pass a fixed date).
    private let wallClock: @Sendable () -> Date
    private let logger: Logger
    private var loop: Task<Void, Never>?
    /// The relay process the bearer went to last.
    private var routerPID: Int?

    /// Renew this long before the token's `exp`.
    package nonisolated static let renewMargin: TimeInterval = 90
    /// Waits after a failure (the daemon and its relay may still be starting), doubling to the last.
    package nonisolated static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120)]

    /// The lease's next wake, and how strictly it is kept (``DelayPolicy``).
    package nonisolated enum Wake: Sendable, Equatable {
        /// The token's renewal: `delay` before ``ModelRouterLease/renewMargin`` ahead of its expiry.
        case renewal(after: Duration)
        /// The next attempt after a failure.
        case retry(after: Duration)

        package var delay: Duration {
            switch self {
            case .renewal(let delay), .retry(let delay): delay
            }
        }

        /// A renewal may run up to its leeway early, never late, so the relay never holds an expired
        /// bearer (`kFlexiblePreferEarly`, base/task/delay_policy.h); a retry is never early.
        package var policy: DelayPolicy {
            switch self {
            case .renewal: .flexiblePreferEarly
            case .retry: .flexibleNoSooner
            }
        }

        /// The ledger owner of its fire.
        package var owner: String {
            switch self {
            case .renewal: "ModelRouterLease.renewal"
            case .retry: "ModelRouterLease.retry"
            }
        }
    }

    package convenience init(tokens: any CloudLeaseTokens, apiBaseURL: URL, acpmuxHome: URL,
                             clock: any Clock<Duration> = ContinuousClock(), logger: Logger) {
        self.init(tokens: tokens, apiBaseURL: apiBaseURL, relay: .local(acpmuxHome: acpmuxHome), clock: clock, logger: logger)
    }

    /// - Parameters:
    ///   - relay: The local relay the bearer goes to.
    ///   - clock: The clock each wait sleeps on; it must count system sleep (the token expires in wall time).
    ///   - wallClock: Now on the wall clock, against which the token's `exp` is read.
    package init(tokens: any CloudLeaseTokens, apiBaseURL: URL, relay: ModelRouterRelay,
                 clock: any Clock<Duration> = ContinuousClock(),
                 // wall-clock: the token's `exp` is Unix seconds (RFC 7519).
                 wallClock: @escaping @Sendable () -> Date = { Date() },
                 logger: Logger) {
        self.tokens = tokens
        self.apiBaseURL = apiBaseURL
        self.relay = relay
        self.clock = clock
        self.wallClock = wallClock
        self.logger = logger
    }

    /// The signed-in account changed (nil: signed out). Restarts the lease loop.
    package func accountChanged(_ userID: String?) {
        loop?.cancel()
        let relay = relay
        guard userID != nil else {
            // task-owner: one clear_upstream; ends with the reply
            loop = Task { try? await relay.clearUpstream() }
            return
        }
        // task-owner: lives while this account is signed in; each pass is one token read and one set_upstream, then a clock wait
        loop = Task { [weak self] in await self?.run() }
    }

    package func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The renewal of a token that expires at `expiresAt` (Unix seconds), at `now`: its wake, and whether
    /// the next read must refresh the token (it is too close to its expiry to renew from).
    package nonisolated static func renewal(expiresAt: UInt64, now: Date) -> (wake: Wake, forceRefresh: Bool) {
        // wall-clock: the token's `exp` is Unix seconds (RFC 7519).
        let remaining = TimeInterval(expiresAt) - now.timeIntervalSince1970
        return (.renewal(after: .seconds(max(10, remaining - renewMargin))), remaining <= renewMargin * 2)
    }

    private func run() async {
        var failures = 0
        var forceRefresh = false
        // wakeup-allow: periodic ModelRouterLease.renewal one pass per token: each waits on one DemandTimer deadline (the renewal, or a retry after a failure) or the relay's exit
        while !Task.isCancelled {
            let wake: Wake
            do {
                guard tokens.isSignedIn, let origin = HomeCloudLease.origin(apiBaseURL) else { return }
                let token = try await tokens.accessToken(forceRefresh: forceRefresh)
                let expiresAtMs = HomeCloudLease.expiry(ofJWT: token) ?? HomeCloudLease.fallbackExpiry(now: wallClock())
                let expiresAt = expiresAtMs / 1000
                let pid = try await relay.setUpstream(origin, token, expiresAt)
                if let pid, let last = routerPID, pid != last {
                    logger.info("model router lease: the local relay restarted (pid \(last) -> \(pid)); bearer sent again")
                }
                routerPID = pid
                failures = 0
                let renewal = Self.renewal(expiresAt: expiresAt, now: wallClock())
                forceRefresh = renewal.forceRefresh
                wake = renewal.wake
            } catch is CancellationError {
                return
            } catch {
                if failures == 0 { logger.info("model router lease: \(String(describing: error), privacy: .public)") }
                wake = .retry(after: Self.retryDelays[min(failures, Self.retryDelays.count - 1)])
                failures += 1
            }
            do { try await waitFor(wake) } catch { return }
        }
    }

    /// Waits for `wake`, or less: a relay process that ends (a daemon
    /// replaced it) wakes the loop at once, because the new relay has
    /// no bearer. A relay that cannot be watched leaves only the clock. The
    /// first of the three (the clock, the relay's exit, cancellation) resumes
    /// the loop; the watch is cancelled, never waited for. Each wait has its
    /// own timer, so a cancelled loop's late cleanup never cancels the next one's.
    private func waitFor(_ wake: Wake) async throws {
        let relay = relay
        let pid = routerPID
        let woken = RenewalWake()
        let timer = DemandTimer(owner: wake.owner, policy: wake.policy, clock: clock)
        // task-owner: this wait; cancelled when it ends, ends when the relay exits
        let watch = Task { if await relay.waitUntilGone(pid) { woken.wake() } }
        await withTaskCancellationHandler {
            try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
                woken.begin(continuation)
                timer.schedule(after: wake.delay) { woken.wake() }
            }
        } onCancel: {
            woken.wake()
        }
        watch.cancel()
        timer.cancel()
        try Task.checkCancellation()
    }
}

/// What ``ModelRouterLease`` asks of the local relay. ``local(acpmuxHome:)`` is ``LocalRouterClient`` over
/// the acpmux socket; tests pass stand-ins.
package nonisolated struct ModelRouterRelay: Sendable {
    /// Hands the relay `bearer` for `origin`, valid until `expiresAt` (Unix seconds); returns the relay's
    /// process id (nil from a relay too old to name it).
    package var setUpstream: @Sendable (_ origin: String, _ bearer: String, _ expiresAt: UInt64) async throws -> Int?
    /// True once relay process `pid` is gone; false at once when no relay can be watched.
    package var waitUntilGone: @Sendable (_ pid: Int?) async -> Bool
    /// Takes the bearer back (sign-out).
    package var clearUpstream: @Sendable () async throws -> Void

    package init(setUpstream: @escaping @Sendable (_ origin: String, _ bearer: String, _ expiresAt: UInt64) async throws -> Int?,
                 waitUntilGone: @escaping @Sendable (_ pid: Int?) async -> Bool,
                 clearUpstream: @escaping @Sendable () async throws -> Void) {
        self.setUpstream = setUpstream
        self.waitUntilGone = waitUntilGone
        self.clearUpstream = clearUpstream
    }

    /// The relay the acpmux daemon of `acpmuxHome` started, over its admin socket.
    package static func local(acpmuxHome: URL) -> ModelRouterRelay {
        let client = LocalRouterClient(acpmuxHome: acpmuxHome)
        return ModelRouterRelay(
            setUpstream: { origin, bearer, expiresAt in try await client.setUpstream(origin: origin, bearer: bearer, expiresAt: expiresAt) },
            waitUntilGone: { pid in await client.waitUntilGone(pid: pid) },
            clearUpstream: { try await client.clearUpstream() })
    }
}

/// Resumes the renewal wait once, for whichever of its wakes comes first;
/// a wake before the wait begins resumes it at once.
private nonisolated final class RenewalWake: Sendable {
    private struct State {
        var continuation: OnceContinuation<Void, OnceContinuationError>?
        var woken = false
    }

    private let state = Mutex(State())

    func begin(_ continuation: OnceContinuation<Void, OnceContinuationError>) {
        let woken = state.withLock { state -> Bool in
            if !state.woken { state.continuation = continuation }
            return state.woken
        }
        if woken { continuation.resume(returning: ()) }
    }

    func wake() {
        let continuation = state.withLock { state -> OnceContinuation<Void, OnceContinuationError>? in
            state.woken = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: ())
    }
}
