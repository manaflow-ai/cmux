import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileTransport
import Foundation
import OSLog

let mobileHostCloudflareRelayLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-host-cloudflare-relay"
)

/// Dials the Cloudflare Durable Objects mobile pairing relay
/// (`workers/presence`'s `MobilePairingRelay` DO) as the Mac's `/host` leg,
/// so a paired Android app — which has no Tailscale or Iroh integration —
/// can reach this Mac by dialing the matching `/client` leg instead of a
/// direct TCP route.
///
/// Mirrors `MobileHostIrohRuntime`'s `setDesiredActive(_:)` composition-root
/// shape, but is far simpler: there is no broker binding or relay policy to
/// manage, just one outbound WebSocket kept alive with reconnect/backoff.
/// Every admitted connection is funneled through the exact same
/// `MobileHostService.acceptTransport(_:authorization:...)` the legacy TCP
/// listener and Iroh both use, with `authorization: .stackBearer` — the same
/// per-request Stack auth gate the TCP listener uses, and the same
/// authorization context `MobileHostConnectionRegistry` already sweeps on
/// `MobileHostService.stop()`, so relay connections are torn down by the
/// existing cleanup path with no extra plumbing.
@MainActor
final class MobileHostCloudflareRelayRuntime {
    static let shared = MobileHostCloudflareRelayRuntime()

    /// Dial failure backoff ladder; resets to the minimum on every successful
    /// connect.
    private static let minBackoffNanoseconds: UInt64 = 1 * 1_000_000_000
    private static let maxBackoffNanoseconds: UInt64 = 30 * 1_000_000_000
    /// Retry cadence while not yet ready to dial (signed out, or identity not
    /// available yet) — steady, not part of the failure backoff ladder.
    private static let notReadyRetryNanoseconds: UInt64 = 5 * 1_000_000_000

    private weak var auth: AuthCoordinator?
    private var desiredActive = false
    private var loopTask: Task<Void, Never>?
    private var generation = UUID()

    private init() {}

    /// Inject the auth dependency. Call once at the composition root,
    /// alongside `MobileHostIrohRuntime.shared.configure(auth:)`.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
    }

    func setDesiredActive(_ active: Bool) {
        desiredActive = active
        if active {
            startLoopIfNeeded()
        } else {
            stopLoop()
        }
    }

    private func startLoopIfNeeded() {
        guard loopTask == nil else {
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        loopTask = Task { [weak self] in
            await self?.runLoop(generation: currentGeneration)
        }
    }

    private func stopLoop() {
        generation = UUID()
        loopTask?.cancel()
        loopTask = nil
        MobileHostPublicStatusCache.update(cloudflareRelayRoute: nil)
    }

    private func isCurrentGeneration(_ candidate: UUID) -> Bool {
        generation == candidate
    }

    private func currentAccessToken() async -> String? {
        guard let auth else {
            return nil
        }
        return try? await auth.currentTokens().accessToken
    }

    private func runLoop(generation currentGeneration: UUID) async {
        var backoffNanoseconds = Self.minBackoffNanoseconds
        while !Task.isCancelled, generation == currentGeneration, desiredActive {
            let macDeviceID = MobileHostIdentity.deviceID().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !macDeviceID.isEmpty,
                  let bearerToken = await currentAccessToken(),
                  let hostURL = Self.relayURL(macDeviceID: macDeviceID, leg: "host") else {
                try? await Task.sleep(nanoseconds: Self.notReadyRetryNanoseconds)
                continue
            }

            let transport = CmxCloudflareRelayByteTransport(url: hostURL, bearerToken: bearerToken)
            do {
                try await transport.connect()
            } catch {
                mobileHostCloudflareRelayLog.info(
                    "mobile host cloudflare relay dial failed: \(String(describing: error), privacy: .public)"
                )
                await transport.close()
                try? await Task.sleep(nanoseconds: backoffNanoseconds)
                backoffNanoseconds = min(backoffNanoseconds * 2, Self.maxBackoffNanoseconds)
                continue
            }
            backoffNanoseconds = Self.minBackoffNanoseconds

            if let clientURL = Self.relayURL(macDeviceID: macDeviceID, leg: "client"),
               let route = try? CmxAttachRoute(
                   id: CmxAttachTransportKind.websocket.rawValue,
                   kind: .websocket,
                   endpoint: .url(clientURL.absoluteString),
                   priority: 0
               ) {
                MobileHostPublicStatusCache.update(cloudflareRelayRoute: route)
            }

            _ = await MobileHostService.acceptTransport(
                transport,
                authorization: .stackBearer,
                isCurrent: { [weak self] in
                    guard let self else {
                        return false
                    }
                    return await self.isCurrentGeneration(currentGeneration)
                }
            )
            MobileHostPublicStatusCache.update(cloudflareRelayRoute: nil)

            guard generation == currentGeneration, desiredActive else {
                return
            }
            try? await Task.sleep(nanoseconds: backoffNanoseconds)
        }
    }

    /// The `/host` or `/client` leg URL for `macDeviceID`, or `nil` when the
    /// resolved base URL is malformed. Mirrors
    /// `PresenceHeartbeatClient.resolvedServiceURL()`'s env-override /
    /// DEBUG-dev / release-production resolution, reusing the exact same
    /// `PresenceSettings` constants — the relay lives on the same worker
    /// already deployed at `presence.cmux.dev`.
    private static func relayURL(macDeviceID: String, leg: String) -> URL? {
        guard let base = resolvedBaseURL(),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        let trimmedPath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(trimmedPath)/v1/mobile-relay/\(macDeviceID)/\(leg)"
        return components.url
    }

    private static func resolvedBaseURL() -> URL? {
        var raw = ProcessInfo.processInfo.environment[PresenceSettings.serviceURLEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == nil || raw?.isEmpty == true {
            #if DEBUG
            raw = PresenceSettings.debugDefaultServiceURL
            #else
            raw = PresenceSettings.productionServiceURL
            #endif
        }
        guard let raw, !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }
}
