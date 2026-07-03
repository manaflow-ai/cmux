import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import os
import CmuxSettings

private let macPairedMacPublishLog = Logger(subsystem: "com.cmuxterm.app", category: "MacPairedMacPublish")

/// DEV convenience: publishes THIS Mac's own attach route into the signed-in
/// user's per-user `pairedMacs` Durable Object backup (`POST /v1/sync/paired-macs`
/// on the presence worker), so a fresh dev iOS build restores it on sign-in and
/// the Mac shows up as a saved host with the real host/port — no manual entry
/// every time a dev build is installed.
///
/// Why a dedicated dev channel: on dev, the device-registry read path points at
/// localhost and the presence `devices` projection isn't wired into the live iOS
/// app yet, so neither delivers the Mac's route to the phone. The per-user
/// `pairedMacs` backup IS reachable from the dev iOS build (it restores from it),
/// so this bridges the gap until those pipelines work on dev.
///
/// Strictly DEV-gated and best-effort, mirroring ``PresenceHeartbeatClient``:
/// a failure never disturbs the Mac, and Release builds never publish.
@MainActor
final class MacPairedMacBackupPublisher {
    static let shared = MacPairedMacBackupPublisher()

    static let envKey = "CMUX_MAC_PAIRED_MAC_SELF_PUBLISH"
    static let defaultsKey = "macPairedMacSelfPublish"

    private let session: URLSession = .shared
    private var auth: AuthCoordinator?
    private var observeTask: Task<Void, Never>?
    /// The routes most recently published, so an unchanged status update (the
    /// common case) does not re-POST.
    private var lastPublishedRoutes: [CmxAttachRoute] = []

    private init() {}

    /// Whether dev self-publish is enabled: env override, then UserDefaults
    /// override, then DEBUG on / Release off (same seam as the other dev flags).
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        func parseBool(_ raw: String) -> Bool {
            switch raw.lowercased() {
            case "1", "true", "yes", "on": return true
            default: return false
            }
        }

        if let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return parseBool(raw)
        }
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Inject auth and start observing routes. Call once at the composition root,
    /// alongside ``PresenceHeartbeatClient``. No-op on Release / when disabled.
    func configure(auth: AuthCoordinator) {
        guard Self.isEnabled() else { return }
        self.auth = auth
        // The iOS-pairing listener defaults ON in DEBUG builds (see
        // MobileCatalogSection.iOSPairingHost), so an attach route comes up
        // without a manual Settings toggle; we just observe and publish it.
        startObserving()
    }

    private func startObserving() {
        guard observeTask == nil else { return }
        observeTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                guard let self, !Task.isCancelled else { break }
                guard !status.routes.isEmpty, status.routes != self.lastPublishedRoutes else { continue }
                await self.publish(routes: status.routes)
            }
        }
    }

    private func publish(routes: [CmxAttachRoute]) async {
        guard let auth, let baseURL = PresenceHeartbeatClient.resolvedServiceURL() else { return }
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            return // not signed in -> nothing to publish
        }
        let teamID = auth.resolvedTeamID

        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path)
            + "/v1/sync/paired-macs"
        guard let url = comps.url else { return }

        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let body = MacPairedMacBackupBody(ops: [
            MacPairedMacBackupOpWire(
                macDeviceID: MobileHostIdentity.deviceID(),
                record: MacPairedMacBackupRecordWire(
                    macDeviceID: MobileHostIdentity.deviceID(),
                    displayName: MobileHostIdentity.displayName(),
                    routes: routes,
                    createdAt: nowMs,
                    lastSeenAt: nowMs,
                    // Mark active so a fresh dev iOS build auto-targets the
                    // running Mac. Restore only honors this when the phone has no
                    // active host (it never hijacks an existing selection).
                    isActive: true
                )
            ),
        ])
        guard let payload = try? JSONEncoder().encode(body) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = payload

        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                macPairedMacPublishLog.warning("self-publish failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            lastPublishedRoutes = routes
            macPairedMacPublishLog.info("published \(routes.count, privacy: .public) route(s) to paired-mac backup")
        } catch {
            macPairedMacPublishLog.warning("self-publish error: \(String(describing: error), privacy: .public)")
        }
    }
}
