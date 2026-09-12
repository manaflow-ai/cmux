#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

extension MobileHostNextTransportRuntime {
    // MARK: - Relay credentials (background mint; schedule-driven renewal)

    func startCredentialLoop(
        endpoint: Endpoint, client: BrokerCredentialClient,
        initialEntries: [NextTransportCachedRelayCredential], generation gen: UInt64
    ) {
        cachedCredentialExpiryTask?.cancel()
        cachedCredentialExpiryTask = nil
        credentialTask?.cancel()
        credentialTask = Task { [weak self] in
            await self?.runCredentialLoop(
                endpoint: endpoint, client: client,
                initialEntries: initialEntries, generation: gen)
        }
    }

    /// Schedules route withdrawal for a cached relay when no broker client is
    /// available to refresh it. The endpoint remains alive for direct LAN
    /// traffic, but the advertised relay is removed as soon as its bounded
    /// validity window ends (or at the fallback cadence when expiry is hidden).
    func startCachedCredentialExpiryWatcher(
        endpoint: Endpoint,
        entries: [NextTransportCachedRelayCredential],
        generation gen: UInt64
    ) {
        guard !entries.isEmpty else { return }
        cachedCredentialExpiryTask?.cancel()
        let sleep = self.sleep
        let now = Int64(Date().timeIntervalSince1970)
        let knownTarget = entries.compactMap(\.expiresAt).min()
        let fallbackTarget = entries.contains { $0.expiresAt == nil }
            ? now + RelayCredentialSchedule.fallbackIntervalSeconds
            : Int64.max
        let target = min(knownTarget ?? Int64.max, fallbackTarget)
        let delay = max(target - now, RelayCredentialSchedule.minimumDelaySeconds)
        cachedCredentialExpiryTask = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
            } catch {
                return
            }
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            self.relayURL = nil
            self.refreshStateDescription()
            if self.readiness == .published {
                self.publishPresenceRoute()
            }
            // Withdraw the whole cache-backed route set at its earliest
            // validity bound. No installed credential may outlive this lease.
            for relayURL in Set(entries.map(\.relayUrl)) {
                _ = try? await endpoint.removeRelay(url: relayURL)
            }
            self.cachedCredentialExpiryTask = nil
            MobileHostNextTransportRuntime.logger.notice(
                "cached relay credential expired; route withdrawn")
        }
    }

    /// Mint / refresh loop. Zero-gap rotation: insert ALONE with the fresh
    /// token (make-before-break; removeRelay would sever live sessions).
    /// Scheduling comes from `RelayCredentialSchedule` (the credentials' own
    /// expiries, lead, jitter) instead of the old fixed 240 s sleep; every
    /// sleep is a cancellable scheduled timer, never a poll. Failures back
    /// off by halving the remaining validity (10 s floor) and, past expiry,
    /// retry at a bounded cadence. A failed mint never tears the endpoint
    /// down: direct paths and any still-valid relay keep serving.
    private func runCredentialLoop(
        endpoint: Endpoint, client: BrokerCredentialClient,
        initialEntries: [NextTransportCachedRelayCredential], generation gen: UInt64
    ) async {
        var entries = initialEntries
        let sleep = self.sleep
        // Nothing on hand (awaitFirstMint) mints immediately; a cached
        // start refreshes on the cache's own schedule.
        var mintImmediately = entries.isEmpty
        while !Task.isCancelled, generation == gen {
            if !mintImmediately {
                let now = Int64(Date().timeIntervalSince1970)
                guard
                    let target = RelayCredentialSchedule().nextRefresh(
                        expiries: entries.map(\.expiresAt),
                        now: now,
                        jitterSeconds: Int64.random(
                            in: 0...NextTransportHostTiming.refreshJitterMaxSeconds))
                else { return }
                MobileHostNextTransportRuntime.logger.notice(
                    """
                    host relay refresh scheduled inSeconds=\(max(target - now, 0), privacy: .public) \
                    earliestExpiry=\(entries.compactMap(\.expiresAt).min().map(String.init) ?? "none", privacy: .public)
                    """)
                do {
                    try await sleep(.seconds(max(target - now, 0)))
                } catch { return }
            }
            mintImmediately = false
            guard !Task.isCancelled, generation == gen else { return }
            do {
                let fresh = try await client.mint(preferredUrl: relayURL)
                guard generation == gen else { return }
                for credential in fresh {
                    try await endpoint.insertRelay(
                        config: RelayConfig(
                            url: credential.relayUrl, authToken: credential.token))
                }
                guard generation == gen else { return }
                entries = relayCachePolicy.entries(from: fresh)
                let previousRelayURL = relayURL
                relayURL = fresh.first?.relayUrl
                await Self.persistCachedRelayCredentials(entries)
                guard generation == gen else { return }
                MobileHostNextTransportRuntime.logger.notice(
                    """
                    host relay credentials rotated zero-gap \
                    count=\(fresh.count, privacy: .public) \
                    cached=\(entries.count, privacy: .public) \
                    first=\(fresh.first?.relayUrl ?? "none", privacy: .public)
                    """)
                if readiness < .relayAttached {
                    // First successful attach on the awaitFirstMint path:
                    // the relay is now in the map and usable, so the host
                    // may advance and publish.
                    setReadiness(.relayAttached, generation: gen)
                    publishIfReady(generation: gen)
                } else if readiness == .published, relayURL != previousRelayURL {
                    // The route carries the relay URL; a rotation that moved
                    // relays must republish it.
                    publishPresenceRoute()
                }
            } catch {
                let now = Int64(Date().timeIntervalSince1970)
                let delay = mintRetryPolicy.retryDelay(
                    earliestExpiry: entries.compactMap(\.expiresAt).min(), now: now)
                MobileHostNextTransportRuntime.logger.error(
                    """
                    credential mint failed: \(String(describing: error), privacy: .public); \
                    retry inSeconds=\(delay, privacy: .public) (endpoint stays up)
                    """)
                do {
                    try await sleep(.seconds(delay))
                } catch { return }
                mintImmediately = true
            }
        }
    }

}
#endif
