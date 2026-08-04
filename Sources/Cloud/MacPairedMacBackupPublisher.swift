import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import os

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
/// so this bridges the gap until those pipelines work on dev. Tagged Mac builds
/// publish directly into the matching tagged iOS partition; stable and untagged
/// builds keep the legacy unscoped partition.
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

        let disclosureDate = Date()
        let nowMs = disclosureDate.timeIntervalSince1970 * 1000.0
        let cloudSafeRoutes = routes.compactMap {
            $0.disclosed(for: .pairedMacCloudBackup, at: disclosureDate)
        }
        let body = MacPairedMacBackupBody(ops: [
            MacPairedMacBackupOpWire(
                macDeviceID: MobileHostIdentity.deviceID(),
                record: MacPairedMacBackupRecordWire(
                    macDeviceID: MobileHostIdentity.deviceID(),
                    displayName: MobileHostIdentity.baseDisplayName(),
                    routes: cloudSafeRoutes,
                    instanceTag: MobileHostIdentity.instanceTag(),
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

        let req = Self.makeRequest(
            url: url,
            accessToken: tokens.accessToken,
            teamID: teamID,
            instanceTag: MobileHostIdentity.instanceTag(),
            payload: payload
        )

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

    /// Builds a self-publish request whose backup partition matches the tagged
    /// iOS build. Stable/untagged instances omit the scope header and preserve
    /// the legacy unscoped collection.
    nonisolated static func makeRequest(
        url: URL,
        accessToken: String,
        teamID: String?,
        instanceTag: String,
        payload: Data
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID, !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        if let clientScope = MobileIOSBuildScope(instanceTag)?.serializedScope {
            request.setValue(clientScope, forHTTPHeaderField: "X-Cmux-Client-Scope")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload
        return request
    }
}
