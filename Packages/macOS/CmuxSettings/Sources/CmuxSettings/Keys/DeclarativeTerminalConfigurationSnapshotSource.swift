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

    /// This source is ready as soon as it is constructed.
    public func waitForInitialSnapshot() async {}
}
