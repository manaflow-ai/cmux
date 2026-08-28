// Mac-side mobile relay host runtime.
//
// Owns the Mac's single outbound WebSocket to its HostRelay Durable Object
// (workers/mobile-relay) and funnels every phone session it announces into
// `MobileHostService.acceptTransport`, which owns RPC dispatch, end-to-end
// session admission (`.relaySession`: the phone's first frame proves the
// account once, later requests are credential-free), event fan-out, and
// connection quotas.
//
// OFF by default: gated on the `mobile.relayHost.enabled` settings key. While
// the toggle is off this runtime never mints a ticket and never dials, so
// "off" is provably zero relay connections. The relay and the Tailscale
// listener are independent transports; neither falls back to the other.

import CmuxRelayTransport
import CmuxSettings
import CmuxAuthRuntime
import Foundation
import OSLog

private let relayHostLog = Logger(subsystem: "dev.cmux", category: "mobile-relay-host")

@MainActor
final class MobileHostRelayRuntime {
    static let shared = MobileHostRelayRuntime()

    private var auth: AuthCoordinator?
    private var desiredActive = false
    private var link: RelayHostLink?
    private var runTask: Task<Void, Never>?

    private init() {}

    /// Inject the auth dependency. Call once at the composition root.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
        reconcile()
    }

    /// Driven by `MobileHostService.syncToSettings()` from the settings key
    /// (and forced off by `stop()` / managed policy).
    func setDesiredActive(_ active: Bool) {
        guard active != desiredActive else { return }
        desiredActive = active
        reconcile()
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        let key = SettingCatalog().mobile.relayHost
        if let override = defaults.object(forKey: key.userDefaultsKey) as? Bool {
            return override
        }
        return key.defaultValue
    }

    private func reconcile() {
        if desiredActive, auth != nil {
            start()
        } else {
            stopLink(reason: "relay host disabled")
        }
    }

    private func start() {
        guard runTask == nil, let auth else { return }
        let link = RelayHostLink(
            hostDeviceID: MobileHostIdentity.deviceID(),
            accessToken: { try await auth.currentTokens().accessToken },
            relayURLOverride: Self.relayURLOverride(),
            onClientSession: { session in
                relayHostLog.info("relay session \(session.sessionID) accepted")
                // Each session carries its own admission: the phone's first
                // frame proves the account end to end before anything else
                // is served (see MobileHostRelayAdmission).
                await MobileHostService.acceptTransport(
                    session.transport,
                    authorization: .relaySession(MobileHostRelayAdmission()),
                    isCurrent: { true }
                )
                relayHostLog.info("relay session \(session.sessionID) ended")
            }
        )
        self.link = link
        relayHostLog.info("relay host runtime starting")
        runTask = Task {
            await link.run()
        }
    }

    private func stopLink(reason: String) {
        guard let link else { return }
        self.link = nil
        let task = runTask
        runTask = nil
        relayHostLog.info("relay host runtime stopping: \(reason, privacy: .public)")
        Task {
            await link.stop()
            task?.cancel()
        }
    }

    /// The host's dial target, resolved through the shared chain (Debug: env
    /// override, else the dev worker; Release: the production constant), so
    /// the Mac and the phone land on the same relay for the same build kind
    /// no matter how either was launched.
    private static func relayURLOverride() -> URL? {
        let resolved = RelayConnectAuth.resolvedRelayURL()
        relayHostLog.info(
            "relay host dial target \(resolved.url?.absoluteString ?? "invalid", privacy: .public) source=\(resolved.source, privacy: .public)"
        )
        return resolved.url
    }
}
