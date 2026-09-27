public import Foundation

/// ``GhosttyConfigLiveReloadSnapshotReading`` that resolves cmux's Ghostty
/// config files through ``GhosttyConfigDiscovery`` and reads them from disk.
///
/// Every input is a `Sendable` value captured at construction, and the
/// discovery value (with its non-`Sendable` file reader) is built inside each
/// call, so ``snapshot()`` runs entirely off the caller's actor.
///
/// ```swift
/// let reader = DiscoveryGhosttyConfigLiveReloadSnapshotReader(
///     currentBundleIdentifier: Bundle.main.bundleIdentifier,
///     appSupportDirectory: FileManager.default.urls(
///         for: .applicationSupportDirectory, in: .userDomainMask
///     ).first,
///     configHomeDirectory: DiscoveryGhosttyConfigLiveReloadSnapshotReader
///         .configHomeDirectory(environment: ProcessInfo.processInfo.environment)
/// )
/// ```
public struct DiscoveryGhosttyConfigLiveReloadSnapshotReader: GhosttyConfigLiveReloadSnapshotReading {
    private let currentBundleIdentifier: String?
    private let appSupportDirectory: URL?
    private let configHomeDirectory: String
    private let makeDiscovery: @Sendable () -> GhosttyConfigDiscovery

    /// Creates a reader.
    ///
    /// - Parameters:
    ///   - currentBundleIdentifier: The running app's bundle identifier, which
    ///     selects the cmux Application Support config directory.
    ///   - appSupportDirectory: The user's Application Support directory.
    ///   - configHomeDirectory: The XDG config home that holds
    ///     `ghostty/themes`.
    ///   - makeDiscovery: Builds the discovery value for one read. Defaults to
    ///     a `FileManager`-backed discovery; tests inject an in-memory reader.
    public init(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL?,
        configHomeDirectory: String,
        makeDiscovery: @escaping @Sendable () -> GhosttyConfigDiscovery = { GhosttyConfigDiscovery() }
    ) {
        self.currentBundleIdentifier = currentBundleIdentifier
        self.appSupportDirectory = appSupportDirectory
        self.configHomeDirectory = configHomeDirectory
        self.makeDiscovery = makeDiscovery
    }

    /// The XDG config home Ghostty uses: `$XDG_CONFIG_HOME` when set to a
    /// non-empty value, otherwise `~/.config`.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: An absolute or `~`-prefixed directory path.
    public static func configHomeDirectory(environment: [String: String]) -> String {
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"],
           !xdgConfigHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return xdgConfigHome
        }
        return "~/.config"
    }

    public func snapshot() async -> GhosttyConfigLiveReloadSnapshot {
        let discovery = makeDiscovery()
        return discovery.liveReloadSnapshot(
            topLevelPaths: discovery.liveReloadTopLevelPaths(
                currentBundleIdentifier: currentBundleIdentifier,
                appSupportDirectory: appSupportDirectory
            ),
            configHomeDirectory: configHomeDirectory
        )
    }
}
