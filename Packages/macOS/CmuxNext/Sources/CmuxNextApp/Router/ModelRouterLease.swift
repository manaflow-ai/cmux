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
                try await router.setUpstream(origin: origin, bearer: token, expiresAt: expiresAt)
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
            do { try await clock.sleep(for: wait, tolerance: .seconds(1)) } catch { return }
        }
    }
}
