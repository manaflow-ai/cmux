public import Foundation

/// Describes one app-bundle-scoped persistent terminal backend service.
///
/// The app bundle identifier is the namespace boundary. Production keeps the
/// stable `cmux` session, while development, staging, and nightly bundles get
/// distinct launchd labels, session names, sockets, and durable state records.
public struct BackendServiceDescriptor: Equatable, Sendable {
    /// The production cmux bundle identifier.
    public static let productionBundleIdentifier = "com.cmuxterm.app"

    /// The stable production backend descriptor.
    public static let production = BackendServiceDescriptor(
        validatedBundleIdentifier: productionBundleIdentifier
    )

    /// The app bundle identifier that owns this service.
    public let bundleIdentifier: String

    /// Stable logical-client UUID shared by reconnects and app relaunches of this bundle.
    public let terminalClientUUID: UUID

    /// The launchd label embedded in the bundled launch-agent property list.
    public let serviceLabel: String

    /// The launch-agent property-list filename inside `Contents/Library/LaunchAgents`.
    public let propertyListName: String

    /// The relative path to the backend executable inside the app bundle.
    public let executableRelativePath: String

    /// The cmux-tui session name passed to the backend process.
    public let sessionName: String

    /// The socket filename produced by cmux-tui's per-user runtime directory.
    public let socketFileName: String

    /// The namespace used by cmux-tui's durable state store.
    ///
    /// cmux-tui hashes this value into a per-session state filename, so sharing
    /// the parent state directory does not share state across app identities.
    public let stateNamespace: String

    /// Creates a descriptor for a valid bundle identifier.
    ///
    /// - Parameter bundleIdentifier: A nonempty identifier containing only
    ///   ASCII letters, digits, periods, hyphens, and underscores.
    public init?(bundleIdentifier: String) {
        guard let identity = BackendServiceIdentity(bundleIdentifier: bundleIdentifier) else { return nil }
        self.init(identity: identity)
    }

    private init(validatedBundleIdentifier bundleIdentifier: String) {
        self.init(identity: BackendServiceIdentity(bundleIdentifier: bundleIdentifier)!)
    }

    private init(identity: BackendServiceIdentity) {
        let bundleIdentifier = identity.normalizedBundleIdentifier
        let serviceLabel = "\(bundleIdentifier).terminal-backend"
        let sessionName = bundleIdentifier == Self.productionBundleIdentifier
            ? "cmux"
            : "cmux-\(identity.token)"

        self.bundleIdentifier = bundleIdentifier
        terminalClientUUID = identity.terminalClientUUID
        self.serviceLabel = serviceLabel
        self.propertyListName = "\(serviceLabel).plist"
        self.executableRelativePath = "Contents/Resources/bin/cmux-terminal-backend"
        self.sessionName = sessionName
        self.socketFileName = "\(sessionName).sock"
        self.stateNamespace = sessionName
    }

}
