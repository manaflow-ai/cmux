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
        guard let computer = directory.computers.first(where: { $0.deviceID == deviceID }) else {
            return nil
        }
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
            retryDelay: HiveReconnectBackoff().delay(attempt:)
        )
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
