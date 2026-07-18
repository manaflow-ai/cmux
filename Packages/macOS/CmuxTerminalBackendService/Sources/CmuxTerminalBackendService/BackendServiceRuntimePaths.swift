public import Foundation

/// Absolute runtime paths shared by the launch agent and app client.
public struct BackendServiceRuntimePaths: Equatable, Sendable {
    /// The private Unix-domain control socket for the app-scoped session.
    public let socketURL: URL

    /// The persistent cmux-tui state directory for the current macOS user.
    public let stateDirectoryURL: URL

    /// Private root containing immutable backend and renderer versions.
    public let serviceInstallationRootURL: URL

    /// Per-user launch-agent descriptor installed for this app identity.
    public let launchAgentPropertyListURL: URL

    /// Derives environment-independent macOS paths for one app identity.
    ///
    /// The socket root matches cmux-tui's short Darwin runtime layout. The
    /// launch-agent mode uses the same layout so `TMPDIR` cannot split clients
    /// and the service across different sockets.
    ///
    /// - Parameters:
    ///   - descriptor: The app-scoped backend identity.
    ///   - userID: The numeric macOS user identifier.
    ///   - homeDirectoryURL: The current user's native home directory.
    public init(
        descriptor: BackendServiceDescriptor,
        userID: UInt32,
        homeDirectoryURL: URL
    ) {
        socketURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-tui-\(userID)", isDirectory: true)
            .appendingPathComponent(descriptor.socketFileName, isDirectory: false)
        stateDirectoryURL = homeDirectoryURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("cmux-tui", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        serviceInstallationRootURL = homeDirectoryURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("terminal-backend", isDirectory: true)
            .appendingPathComponent(descriptor.bundleIdentifier, isDirectory: true)
        launchAgentPropertyListURL = homeDirectoryURL
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(descriptor.propertyListName, isDirectory: false)
    }
}
