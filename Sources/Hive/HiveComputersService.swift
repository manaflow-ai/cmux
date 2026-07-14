import CmuxAuthRuntime
import CmuxHive
import CmuxMobilePairedMac
import CmuxMobileShell
import Foundation

/// App-side composition of the hive computers directory: wires the shared
/// device-registry client, the local paired-computer store, and the presence
/// subscriber (the same client stack the iOS app composes) to the signed-in
/// account, and hands the resulting ``HiveComputerDirectory`` to the
/// Settings › Computers pane.
///
/// Follows the house pattern of the other cloud clients configured at the
/// composition root (``DeviceRegistryClient``, ``PresenceHeartbeatClient``):
/// a `shared` instance that stays inert until `configure(auth:)`.
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
        let store: MobilePairedMacStore
        do {
            store = try MobilePairedMacStore(databaseURL: Self.pairedComputersDatabaseURL())
        } catch {
            NSLog("cmux.hive paired-computer store unavailable: %@", String(describing: error))
            return
        }
        let apiBaseURL = Self.normalizedBaseURL(AuthEnvironment.vmAPIBaseURL)
        let registry = DeviceRegistryService(
            apiBaseURL: apiBaseURL,
            deviceID: MobileHostIdentity.deviceID(),
            tokenSource: DeviceRegistryService.TokenSource(
                accessToken: { (try? await auth.currentTokens())?.accessToken },
                refreshToken: { (try? await auth.currentTokens())?.refreshToken }
            ),
            teamIDProvider: { await auth.resolvedTeamID }
        )
        let presence: PresenceClient?
        if let presenceURL = PresenceHeartbeatClient.resolvedServiceURL() {
            presence = PresenceClient(
                serviceBaseURL: Self.normalizedBaseURL(presenceURL),
                tokenSource: PresenceTokenSource(
                    accessToken: { (try? await auth.currentTokens())?.accessToken },
                    currentUserID: { await auth.currentUser?.id }
                ),
                teamIDProvider: { await auth.resolvedTeamID }
            )
        } else {
            presence = nil
        }
        directory = HiveComputerDirectory(
            registry: registry,
            pairedStore: store,
            presence: presence,
            ownDeviceID: MobileHostIdentity.deviceID(),
            scopeProvider: {
                await HiveAccountScope(
                    stackUserID: auth.currentUser?.id,
                    teamID: auth.resolvedTeamID
                )
            },
            linkDecoder: HivePairingLinkDecoder(allowsLoopbackRoutes: Self.allowsLoopbackPairing),
            presenceRetryDelay: { attempt in
                // Bounded, cancellable resubscribe backoff for the presence
                // stream (a genuine delay, not a poll): 1s doubling to 60s.
                let seconds = min(60.0, pow(2.0, Double(min(attempt, 6))))
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
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

    /// The Mac-side paired-computer database. Uses its own file (not the
    /// phone's `paired-macs.sqlite3` name) so the namespace stays clearly
    /// Mac-as-client.
    private static func pairedComputersDatabaseURL() throws -> URL {
        try MobilePairedMacStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("hive-paired-computers.sqlite3")
    }

    private static func normalizedBaseURL(_ url: URL) -> String {
        let raw = url.absoluteString
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
}
