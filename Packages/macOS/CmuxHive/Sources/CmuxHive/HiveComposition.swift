internal import CmuxMobilePairedMac
internal import CmuxMobileShell
import Foundation

/// Builds the hive computers directory from app-supplied configuration,
/// naming the concrete registry / paired-store / presence implementations
/// inside the package.
///
/// The app's composition root decides *what* to wire (URLs, tokens, device
/// identity, policy) and this factory owns *which concrete types* implement
/// the directory's seams. Keeping the concrete construction here means the
/// app target links only `CmuxHive` — it never has to declare (or even know
/// about) the client-stack packages the directory composes, so adding a new
/// source to the merge cannot ripple into the app's package-product graph.
@MainActor
public struct HiveComposition {
    /// Everything the directory's sources need, supplied by the app root.
    public struct Configuration: Sendable {
        /// The cmux web API base URL, no trailing slash (`/api/devices` host).
        public var apiBaseURL: String
        /// The presence worker base URL, or `nil` to run without live presence.
        public var presenceBaseURL: String?
        /// This computer's stable registry device id.
        public var ownDeviceID: String
        /// Accept loopback pairing links/routes (dev builds only).
        public var allowsLoopbackRoutes: Bool
        /// Returns the current Stack access token, or `nil` when signed out.
        public var accessToken: @Sendable () async -> String?
        /// Returns the current Stack refresh token, or `nil` when signed out.
        public var refreshToken: @Sendable () async -> String?
        /// Returns the signed-in Stack user id, or `nil` when signed out.
        public var currentUserID: @Sendable () async -> String?
        /// Returns the selected team id, or `nil` for the default scope.
        public var teamID: @Sendable () async -> String?

        public init(
            apiBaseURL: String,
            presenceBaseURL: String?,
            ownDeviceID: String,
            allowsLoopbackRoutes: Bool,
            accessToken: @escaping @Sendable () async -> String?,
            refreshToken: @escaping @Sendable () async -> String?,
            currentUserID: @escaping @Sendable () async -> String?,
            teamID: @escaping @Sendable () async -> String?
        ) {
            self.apiBaseURL = apiBaseURL
            self.presenceBaseURL = presenceBaseURL
            self.ownDeviceID = ownDeviceID
            self.allowsLoopbackRoutes = allowsLoopbackRoutes
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.currentUserID = currentUserID
            self.teamID = teamID
        }
    }

    private let configuration: Configuration

    /// Creates a composition over the app-supplied configuration.
    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Builds the merged computers directory: the team device registry, the
    /// local paired-computer store, and (when configured) the live presence
    /// stream.
    ///
    /// - Throws: The paired-computer store's error when its SQLite database
    ///   cannot be opened.
    public func makeDirectory() throws -> HiveComputerDirectory {
        let configuration = configuration
        let store = try MobilePairedMacStore(databaseURL: Self.pairedComputersDatabaseURL())
        let registry = DeviceRegistryService(
            apiBaseURL: configuration.apiBaseURL,
            deviceID: configuration.ownDeviceID,
            tokenSource: DeviceRegistryService.TokenSource(
                accessToken: configuration.accessToken,
                refreshToken: configuration.refreshToken
            ),
            teamIDProvider: configuration.teamID
        )
        let presence: (any PresenceSubscribing)?
        if let presenceBaseURL = configuration.presenceBaseURL {
            presence = PresenceClient(
                serviceBaseURL: presenceBaseURL,
                tokenSource: PresenceTokenSource(
                    accessToken: configuration.accessToken,
                    currentUserID: configuration.currentUserID
                ),
                teamIDProvider: configuration.teamID
            )
        } else {
            presence = nil
        }
        return HiveComputerDirectory(
            registry: registry,
            pairedStore: store,
            presence: presence,
            ownDeviceID: configuration.ownDeviceID,
            scopeProvider: { [currentUserID = configuration.currentUserID, teamID = configuration.teamID] in
                await HiveAccountScope(stackUserID: currentUserID(), teamID: teamID())
            },
            linkDecoder: HivePairingLinkDecoder(
                allowsLoopbackRoutes: configuration.allowsLoopbackRoutes
            ),
            presenceRetryDelay: { @Sendable attempt in
                await HiveReconnectBackoff(maximumSeconds: 60).delay(attempt: attempt)
            }
        )
    }

    /// The Mac-side paired-computer database. Its own file (not the phone's
    /// `paired-macs.sqlite3` name) so the Mac-as-client namespace is distinct.
    private static func pairedComputersDatabaseURL() throws -> URL {
        try MobilePairedMacStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("hive-paired-computers.sqlite3")
    }
}
