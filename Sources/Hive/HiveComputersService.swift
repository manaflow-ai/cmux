import CmuxAuthRuntime
import CmuxHive
import Foundation

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
            NSLog("cmux.hive paired-computer store unavailable: %@", String(describing: error))
        }
    }

    /// Builds a live viewing session onto one paired computer, or `nil` when
    /// the computer has no local pairing record (the Computers pane only
    /// offers Open on paired rows) or auth is not configured.
    func makeViewerSession(deviceID: String) async -> HiveRemoteMacSession? {
        guard let auth, let directory else { return nil }
        var computer = directory.computers.first(where: { $0.deviceID == deviceID })
        if computer == nil {
            // On a fresh launch the directory is empty until something (the
            // Settings pane, the scope picker) refreshes it. An open request
            // arriving first — relaunch restore, `hive.open` RPC — must not
            // fail on that ordering; load the pairings/registry and re-check.
            await directory.refresh()
            computer = directory.computers.first(where: { $0.deviceID == deviceID })
        }
        guard let computer else { return nil }
        // Prefer the freshest routes: a live online instance's advertised set,
        // falling back to whatever the pairing/registry row carries.
        guard let best = computer.bestPairingRoutes else { return nil }
        let runtime = HiveSyncRuntime.network(
            allowsLoopbackRoutes: Self.allowsLoopbackPairing,
            stackAccessTokenProvider: { try await auth.accessToken() },
            stackAccessTokenForceRefresher: { try await auth.forceRefreshAccessToken() }
        )
        return HiveRemoteMacSession(
            runtime: runtime,
            macDeviceID: deviceID,
            displayName: computer.displayName,
            routes: best.routes,
            retryDelay: { @Sendable attempt in
                await HiveReconnectBackoff().delay(attempt: attempt)
            }
        )
    }

    /// Live sessions backing the main window's embedded computer pages
    /// (`computers.presentation = sidebar`), one per device, so scope
    /// switches reuse the connection instead of re-dialing.
    private var embeddedSessions: [String: HiveRemoteMacSession] = [:]

    /// The cached embedded-viewer session for a device, creating and
    /// connecting one on first use. Returns `nil` when the computer has no
    /// pairing record or auth is not configured.
    func embeddedSession(deviceID: String) async -> HiveRemoteMacSession? {
        if let existing = embeddedSessions[deviceID] { return existing }
        guard let session = await makeViewerSession(deviceID: deviceID) else { return nil }
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
    func retryConnection(deviceID: String) {
        embeddedSessions[deviceID]?.connect()
    }

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
