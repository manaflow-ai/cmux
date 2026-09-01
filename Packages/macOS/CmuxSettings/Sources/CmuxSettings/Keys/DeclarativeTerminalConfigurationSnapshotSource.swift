import Foundation

/// An immutable configuration source for isolated callers and tests.
///
/// Production composition uses the app's long-lived settings observer. This
/// source exists for package/app tests that need deterministic values without
/// starting a file watcher or a settings UI observer.
@MainActor
public final class DeclarativeTerminalConfigurationSnapshotSource:
    DeclarativeTerminalConfigurationProviding
{
    /// The fixed snapshot returned to every consumer.
    public let snapshot: DeclarativeTerminalConfiguration.Snapshot

    /// The file identity associated with ``snapshot``.
    public let fileURL: URL

    /// Creates an immutable source.
    ///
    /// - Parameters:
    ///   - snapshot: Values returned to consumers.
    ///   - fileURL: File identity associated with those values.
    public init(
        snapshot: DeclarativeTerminalConfiguration.Snapshot = .init(),
        fileURL: URL = CmuxConfigLocation().userConfigFile
    ) {
        self.snapshot = snapshot
        self.fileURL = fileURL.standardizedFileURL
    }

    /// Creates a ready source whose compatibility fallback mirrors the legacy
    /// UserDefaults inheritance setting.
    ///
    /// - Parameters:
    ///   - fileURL: File identity associated with the source.
    ///   - legacyInheritanceEnabled: Value used when the declarative policy
    ///     key is absent or invalid.
    public convenience init(
        fileURL: URL = CmuxConfigLocation().userConfigFile,
        legacyInheritanceEnabled: Bool
    ) {
        self.init(
            snapshot: DeclarativeTerminalConfiguration.Snapshot(
                legacyInheritanceEnabled: legacyInheritanceEnabled
            ),
            fileURL: fileURL
        )
    }

    /// This source is ready as soon as it is constructed.
    public func waitForInitialSnapshot() async {}
}
