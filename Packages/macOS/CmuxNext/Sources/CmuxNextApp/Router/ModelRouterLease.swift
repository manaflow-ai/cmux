import CmuxNextAgentPane
import Foundation
import os

/// Gives the local model relay (cmux-tui crate cmux-coderouter, started by
/// the acpmux daemon) the signed-in account's bearer for the hosted cmux
/// model router, and takes it back on sign-out (plans/cmux-next/model-router.md,
/// cx-dna4.4). The relay holds the bearer in memory only; agents reach the
/// router through the relay with its own per-session keys, never with this
/// token. The lease renews shortly before the token expires.
@MainActor final class ModelRouterLease {
    private let tokens: any CloudLeaseTokens
    private let apiBaseURL: URL
    private let router: LocalRouterClient
    private let clock: any Clock<Duration>
    private let logger: Logger
    private var loop: Task<Void, Never>?
    /// The relay process the bearer went to last.
    private var routerPID: Int?

    /// Renew this long before the token's `exp`.
    nonisolated static let renewMargin: TimeInterval = 90
    /// Waits after a failure (the daemon and its relay may still be starting), doubling to the last.
    nonisolated static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120)]

    init(tokens: any CloudLeaseTokens, apiBaseURL: URL, acpmuxHome: URL, clock: any Clock<Duration> = ContinuousClock(),
         logger: Logger) {
        self.tokens = tokens
        self.apiBaseURL = apiBaseURL
        router = LocalRouterClient(acpmuxHome: acpmuxHome)
        self.clock = clock
        self.logger = logger
    }

    /// The signed-in account changed (nil: signed out). Restarts the lease loop.
    func accountChanged(_ userID: String?) {
        loop?.cancel()
        let router = router
        guard userID != nil else {
            // task-owner: one clear_upstream; ends with the reply
            loop = Task { try? await router.clearUpstream() }
            return
        }
        // task-owner: lives while this account is signed in; each pass is one token read and one set_upstream, then a clock wait
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func run() async {
        var failures = 0
        var forceRefresh = false
        while !Task.isCancelled {  // wakeup-allow: each pass waits on the injected clock until the token's renewal time
            let wait: Duration
            do {
                guard tokens.isSignedIn, let origin = HomeCloudLease.origin(apiBaseURL) else { return }
                let token = try await tokens.accessToken(forceRefresh: forceRefresh)
                let expiresAtMs = HomeCloudLease.expiry(ofJWT: token) ?? HomeCloudLease.fallbackExpiry(now: Date())
                let expiresAt = expiresAtMs / 1000
                let pid = try await router.setUpstream(origin: origin, bearer: token, expiresAt: expiresAt)
                if let pid, let last = routerPID, pid != last {
                    logger.info("model router lease: the local relay restarted (pid \(last) -> \(pid)); bearer sent again")
                }
                routerPID = pid
                failures = 0
                let remaining = TimeInterval(expiresAt) - Date().timeIntervalSince1970
                forceRefresh = remaining <= Self.renewMargin * 2
                wait = .seconds(max(10, remaining - Self.renewMargin))
            } catch is CancellationError {
                return
            } catch {
                if failures == 0 { logger.info("model router lease: \(String(describing: error), privacy: .public)") }
                wait = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
                failures += 1
            }
            // wakeup-allow: one wait per pass: until the token's renewal time, the relay's exit, or the next retry delay after a failure
            do { try await waitForRenewal(wait) } catch { return }
        }
    }

    /// Waits until the renewal time, or less: a relay process that ends (a
    /// daemon replaced it) wakes the loop at once, because the new relay has
    /// no bearer. A relay that cannot be watched leaves only the clock.
    private func waitForRenewal(_ wait: Duration) async throws {
        let clock = clock
        let router = router
        let pid = routerPID
        try await withThrowingTaskGroup(of: Void.self) { group in
            // task-owner: the group; cancelled when the other wait ends first
            group.addTask { try await clock.sleep(for: wait, tolerance: .seconds(1)) }
            // task-owner: the group; ends when the relay exits, or sleeps like the clock when it cannot be watched
            group.addTask {
                if await !router.waitUntilGone(pid: pid) { try await clock.sleep(for: wait, tolerance: .seconds(1)) }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
