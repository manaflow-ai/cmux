/// A known Safari application and extension signing identity.
public struct BrowserWebExtensionSafariAppIdentity: Equatable, Identifiable, Sendable {
    /// Stable catalog identity.
    public let id: String

    /// Containing application bundle identifier.
    public let appBundleIdentifier: String

    /// Safari WebExtension bundle identifier.
    public let extensionBundleIdentifier: String

    /// Apple Developer Team identifier required on both bundles.
    public let teamIdentifier: String

    /// Creates a trusted Safari application identity.
    public init(
        id: String,
        appBundleIdentifier: String,
        extensionBundleIdentifier: String,
        teamIdentifier: String
    ) {
        self.id = id
        self.appBundleIdentifier = appBundleIdentifier
        self.extensionBundleIdentifier = extensionBundleIdentifier
        self.teamIdentifier = teamIdentifier
    }
}
