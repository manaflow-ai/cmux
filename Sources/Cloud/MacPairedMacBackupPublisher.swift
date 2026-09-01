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
/// so this bridges the gap until those pipelines work on dev. Every Mac build
/// publishes into the exact iOS bundle that completed the pairing handshake.
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
    private var authObserveTask: Task<Void, Never>?
    /// Every observer feeds one ordered publish chain. The network request is
    /// still asynchronous, but a newer route/target cannot finish before an
    /// older request and leave the backup namespace stale.
    private var publishTask: Task<Void, Never>?
    private var publishSequence = 0
    /// The routes most recently published, so an unchanged status update (the
    /// common case) does not re-POST.
    private var lastPublishedRoutes: [CmxAttachRoute] = []
    /// A target change must republish unchanged routes into the new backup
    /// namespace (for example, after pairing a beta build after App Store).
    private var lastPublishedBundleIdentifier: String?

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
        observeTask?.cancel()
        authObserveTask?.cancel()
        publishSequence &+= 1
        // Keep the cancelled handle until it settles. URLSession cancellation
        // is cooperative, and dropping this reference would let the next
        // configuration start a request concurrently with the old one.
        publishTask?.cancel()
        observeTask = nil
        authObserveTask = nil
        lastPublishedRoutes = []
        lastPublishedBundleIdentifier = nil
        // The iOS-pairing listener defaults ON in DEBUG builds (see
        // MobileCatalogSection.iOSPairingHost), so an attach route comes up
        // without a manual Settings toggle; we just observe and publish it.
        startObserving()
        startObservingAuth(auth)
    }

    private func startObserving() {
        guard observeTask == nil else { return }
        observeTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                guard let self, !Task.isCancelled else { break }
                let accountID = self.auth?.authenticatedSessionIdentity?.accountID
                let targetBundleIdentifier = MobileHostService.shared
                    .pairedPhoneBackupBundleIdentifier(accountID: accountID)
                guard !status.routes.isEmpty,
                      targetBundleIdentifier != nil,
                      status.routes != self.lastPublishedRoutes
                        || targetBundleIdentifier != self.lastPublishedBundleIdentifier else {
                    continue
                }
                await self.publish(routes: status.routes)
            }
        }
    }

    /// Replays the current routes after auth restoration. The host-status
    /// stream can yield before Stack has published its identity, so relying on
    /// that first yield alone would permanently skip an otherwise valid backup.
    private func startObservingAuth(_ auth: AuthCoordinator) {
        authObserveTask = Task { @MainActor [weak self, weak auth] in
            guard let self, let auth else { return }
            await auth.awaitBootstrapped()
            guard !Task.isCancelled, self.auth === auth else { return }
            for await identity in auth.authenticatedSessionIdentities() {
                guard !Task.isCancelled, self.auth === auth else { return }
                guard identity != nil else {
                    self.lastPublishedRoutes = []
                    self.lastPublishedBundleIdentifier = nil
                    continue
                }
                let routes = MobileHostService.shared.statusSnapshot().routes
                let targetBundleIdentifier = MobileHostService.shared
                    .pairedPhoneBackupBundleIdentifier(accountID: identity?.accountID)
                guard !routes.isEmpty,
                      targetBundleIdentifier != self.lastPublishedBundleIdentifier
                        || routes != self.lastPublishedRoutes else {
                    continue
                }
                await self.publish(routes: routes)
            }
        }
    }

    private func publish(routes: [CmxAttachRoute]) async {
        publishSequence &+= 1
        let sequence = publishSequence
        let previous = publishTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled,
                  let self,
                  self.publishSequence == sequence else { return }
            await self.performPublish(routes: routes)
            guard self.publishSequence == sequence else { return }
            self.publishTask = nil
        }
        publishTask = task
        await task.value
    }

    private func performPublish(routes: [CmxAttachRoute]) async {
        guard let auth, let baseURL = PresenceHeartbeatClient.resolvedServiceURL() else { return }
        let sessionSnapshot: AuthenticatedSessionSnapshot
        do {
            // Capture account identity and credentials as one session snapshot.
            // Reading `currentTokens()` and `authenticatedSessionIdentity`
            // separately can pair one account's bearer with another account's
            // backup namespace across a sign-out or account switch.
            sessionSnapshot = try await auth.authenticatedSessionSnapshot()
        } catch {
            return // not signed in -> nothing to publish
        }
        guard await auth.isAuthenticatedSessionCurrent(sessionSnapshot) else {
            return
        }
        let teamID = auth.resolvedTeamID
        let accountID = sessionSnapshot.accountID
        guard let targetBundleIdentifier = MobileHostService.shared
            .pairedPhoneBackupBundleIdentifier(accountID: accountID),
              let targetNamespace = MobileIOSAppNamespace(
                  bundleIdentifier: targetBundleIdentifier
              ) else {
            return
        }
        // The target is account-scoped state. Re-check the same snapshot after
        // reading it and immediately before constructing the request so a
        // transition cannot tear the auth/namespace pair.
        guard await auth.isAuthenticatedSessionCurrent(sessionSnapshot) else {
            return
        }

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
            accessToken: sessionSnapshot.accessToken,
            refreshToken: sessionSnapshot.refreshToken,
            teamID: teamID,
            targetNamespace: targetNamespace,
            payload: payload
        )

        do {
            guard await auth.isAuthenticatedSessionCurrent(sessionSnapshot) else {
                return
            }
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                macPairedMacPublishLog.warning("self-publish failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            guard await auth.isAuthenticatedSessionCurrent(sessionSnapshot),
                  MobileHostService.shared.pairedPhoneBundleIdentifier(
                      accountID: sessionSnapshot.accountID
                  ) == targetNamespace.bundleIdentifier else {
                return
            }
            lastPublishedRoutes = routes
            lastPublishedBundleIdentifier = targetNamespace.bundleIdentifier
            macPairedMacPublishLog.info("published \(routes.count, privacy: .public) route(s) to paired-mac backup")
        } catch {
            macPairedMacPublishLog.warning("self-publish error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Builds a request for the exact iOS bundle that completed pairing.
    nonisolated static func makeRequest(
        url: URL,
        accessToken: String,
        refreshToken: String? = nil,
        teamID: String?,
        targetNamespace: MobileIOSAppNamespace,
        payload: Data
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let refreshToken, !refreshToken.isEmpty {
            request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        }
        if let teamID, !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        request.setValue(
            targetNamespace.serverScope,
            forHTTPHeaderField: "X-Cmux-Client-Scope"
        )
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload
        return request
    }

}
