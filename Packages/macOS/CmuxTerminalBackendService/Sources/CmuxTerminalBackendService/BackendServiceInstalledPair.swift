public import Foundation

/// A fully validated immutable daemon and renderer installation.
public struct BackendServiceInstalledPair: Equatable, Sendable {
    /// Manifest schema understood by this app build.
    public static let manifestSchemaVersion = 1

    /// Content-derived build identity shared by both executables.
    public let buildID: String

    /// Immutable directory containing the exact sibling executables.
    public let installationDirectoryURL: URL

    /// Absolute daemon path loaded by launchd.
    public let backendExecutableURL: URL

    /// Exact sibling path resolved by the running daemon.
    public let rendererExecutableURL: URL

    /// Integrity manifest validated before this descriptor was returned.
    public let manifestURL: URL

    /// Creates a validated-pair descriptor.
    public init(
        buildID: String,
        installationDirectoryURL: URL,
        backendExecutableURL: URL,
        rendererExecutableURL: URL,
        manifestURL: URL
    ) {
        self.buildID = buildID
        self.installationDirectoryURL = installationDirectoryURL
        self.backendExecutableURL = backendExecutableURL
        self.rendererExecutableURL = rendererExecutableURL
        self.manifestURL = manifestURL
    }
}

/// Outcome of attempting to activate a staged pair without disturbing a live daemon.
public enum BackendServicePairActivationResult: Equatable, Sendable {
    /// The staged pair became the launchd descriptor.
    case activated(BackendServiceInstalledPair)

    /// A live descriptor remains loaded and must complete an explicit safe handoff first.
    case deferred(active: BackendServiceInstalledPair)
}
