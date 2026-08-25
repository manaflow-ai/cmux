import CmuxAuthRuntime
import CmuxHive
import Foundation
import OSLog

/// App-side owner of the hive computers directory (the merged registry +
/// pairings + presence list behind Settings › Computers).
///
/// The composition root supplies configuration only — URLs, tokens, device
/// identity, loopback policy — and `HiveComposition` (in the CmuxHive
/// package) names the concrete client-stack types, so the app target depends
/// on nothing below CmuxHive. Follows the house pattern of the other cloud
/// clients configured at the root (``DeviceRegistryClient``,
/// ``PresenceHeartbeatClient``): a `shared` instance that stays inert until
/// `configure(auth:)`.
@MainActor
final class HiveComputersService {
    static let shared = HiveComputersService()

    private(set) var directory: HiveComputerDirectory?
    private(set) var auth: AuthCoordinator?

    private init() {}

    /// Whether a user session exists right now (drives the pane's
    /// signed-out empty state).
    var isSignedIn: Bool {
        auth?.currentUser != nil
    }

    /// Legacy Tailscale TCP has no cryptographic transport-admission handshake.
    /// Keep viewer actions gated until that protocol is available; DEBUG
    /// loopback remains reachable through the direct mirror path.
    var viewerTransportAvailable: Bool { false }

    /// Inject the auth dependency and build the directory. Call once at the
    /// composition root alongside the other cloud clients.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
        guard directory == nil else { return }
        let composition = HiveComposition(configuration: HiveComposition.Configuration(
            apiBaseURL: Self.normalizedBaseURL(AuthEnvironment.vmAPIBaseURL),
            presenceBaseURL: PresenceHeartbeatClient.resolvedServiceURL().map(Self.normalizedBaseURL),
            ownDeviceID: MobileHostIdentity.deviceID(),
            allowsLoopbackRoutes: Self.allowsLoopbackPairing,
            accessToken: { (try? await auth.currentTokens())?.accessToken },
            refreshToken: { (try? await auth.currentTokens())?.refreshToken },
            currentUserID: { await auth.currentUser?.id },
            teamID: { await auth.resolvedTeamID }
        ))
        do {
            directory = try composition.makeDirectory()
        } catch {
            Logger(subsystem: "com.cmux.app", category: "HiveComputersService")
                .error("Paired-computer store unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Builds a live viewing session onto one paired computer, or `nil` when
    /// the computer has no local pairing record (the Computers pane only
    /// offers Open on paired rows) or auth is not configured.
    func makeViewerSession(deviceID: String) async -> HiveRemoteMacSession? {
        guard let auth, let directory else { return nil }
        // Always bind a viewer to the current account/team snapshot. A cached
        // row can otherwise survive a team switch and authorize the old
        // team's routes until the next settings refresh.
        await directory.refresh()
        return makeViewerSessionFromCurrentDirectory(
            deviceID: deviceID,
            auth: auth,
            directory: directory
        )
    }

    private func makeViewerSessionFromCurrentDirectory(
        deviceID: String,
        auth: AuthCoordinator,
        directory: HiveComputerDirectory
    ) -> HiveRemoteMacSession? {
        let computer = directory.computers.first(where: { $0.deviceID == deviceID })
        guard let computer else { return nil }
        guard computer.isPaired else { return nil }
        // Prefer the freshest routes: a live online instance's advertised set,
        // falling back to whatever the pairing/registry row carries.
        guard let best = computer.bestPairingRoutes else { return nil }
        let runtime = HiveSyncRuntime.network(
            allowsLoopbackRoutes: Self.allowsLoopbackPairing,
            stackAccessTokenProvider: { try await auth.accessToken() },
            stackAccessTokenForceRefresher: { try await auth.forceRefreshAccessToken() },
            stackAccessTokenForStatusProvider: { try? await auth.accessToken() }
        )
        return HiveRemoteMacSession(
            runtime: runtime,
            macDeviceID: deviceID,
            displayName: computer.displayName,
            routes: best.routes,
            sourceRoutes: best.routes,
            retryDelay: { @Sendable attempt in
                await HiveReconnectBackoff().delay(attempt: attempt)
            },
            // Legacy Tailscale TCP has no cryptographic pre-bearer identity
            // admission. Keep Stack auth loopback-only until the transport
            // handshake grows that proof; DEBUG loopback remains usable.
            stackAuthChannelTrust: .loopbackOnly,
            expectedInstanceTag: best.instanceTag,
            requiresHostIdentity: computer.isRegistryBacked
        )
    }

    /// Live sessions backing the main window's embedded computer pages
    /// (`computers.presentation = sidebar`), one per device, so scope
    /// switches reuse the connection instead of re-dialing.
    private var embeddedSessions: [String: HiveRemoteMacSession] = [:]
    private var embeddedScope: HiveAccountScope?

    /// The cached embedded-viewer session for a device, creating and
    /// connecting one on first use. Returns `nil` when the computer has no
    /// pairing record or auth is not configured.
    func embeddedSession(deviceID: String) async -> HiveRemoteMacSession? {
        guard let directory else { return nil }
        await refreshEmbeddedDirectory(directory)
        if let existing = embeddedSessions[deviceID] {
            let computer = directory.computers.first(where: { $0.deviceID == deviceID })
            let best = computer?.bestPairingRoutes
            let bindingChanged = computer == nil
                || computer?.isPaired != true
                || best?.routes != existing.sourceRoutes
                || best?.instanceTag != existing.expectedInstanceTag
                || computer?.isRegistryBacked != existing.requiresHostIdentity
            if bindingChanged {
                embeddedSessions.removeValue(forKey: deviceID)
                await existing.disconnect()
            } else {
                return existing
            }
        }
        guard let auth else { return nil }
        guard let session = makeViewerSessionFromCurrentDirectory(
            deviceID: deviceID,
            auth: auth,
            directory: directory
        ) else { return nil }
        // Re-check after the await: a concurrent first call may have won.
        if let existing = embeddedSessions[deviceID] {
            await session.disconnect()
            return existing
        }
        session.connect()
        embeddedSessions[deviceID] = session
        return session
    }

    /// Tears down the embedded session for a device (unpair, sign-out).
    func discardEmbeddedSession(deviceID: String) async {
        guard let session = embeddedSessions.removeValue(forKey: deviceID) else { return }
        await session.disconnect()
    }

    /// Tear down all remote viewer sessions when the account is signed out.
    func disconnectAll() async {
        await HiveComputerMirrorController.shared.detachAll()
        await HiveViewerWindowController.shared.closeAll()
        let sessions = embeddedSessions.values
        embeddedSessions.removeAll()
        embeddedScope = nil
        for session in sessions {
            await session.disconnect()
        }
        directory?.clearForSignOut()
    }

    private func refreshEmbeddedDirectory(_ directory: HiveComputerDirectory) async {
        await directory.refresh()
        guard let auth else {
            let staleSessions = Array(embeddedSessions.values)
            embeddedSessions.removeAll()
            embeddedScope = nil
            for session in staleSessions {
                await session.disconnect()
            }
            return
        }
        let scope = HiveAccountScope(
            stackUserID: auth.currentUser?.id,
            teamID: auth.resolvedTeamID
        )
        guard embeddedScope != scope else { return }
        let staleSessions = Array(embeddedSessions.values)
        embeddedSessions.removeAll()
        embeddedScope = scope
        for session in staleSessions {
            await session.disconnect()
        }
    }

    /// The live connection phase for a device's embedded viewer session
    /// (Settings Open, sidebar scope picker, or `hive.open`), if one has been
    /// created. `nil` before any attach attempt — callers treat that as "never
    /// tried" rather than "failed". `HiveRemoteMacSession` is `@Observable`,
    /// so reading `.phase` from a SwiftUI `body` tracks it like any other
    /// observable property; no polling needed.
    func connectionPhase(deviceID: String) -> HiveRemoteMacSession.Phase? {
        embeddedSessions[deviceID]?.phase
    }

    /// Forces a fresh connection attempt for a device's embedded viewer
    /// session (sidebar "Retry" button). No-ops if no session exists yet —
    /// that only happens before the first attach, which already retries on
    /// its own.
    /// Dev builds may pair over loopback so two instances on one machine can
    /// dogfood Mac-to-Mac viewing; release builds never dial themselves.
    private static var allowsLoopbackPairing: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func normalizedBaseURL(_ url: URL) -> String {
        let raw = url.absoluteString
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
}
