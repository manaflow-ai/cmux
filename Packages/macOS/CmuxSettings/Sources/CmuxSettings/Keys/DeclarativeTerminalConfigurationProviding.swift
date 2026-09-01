import Foundation

/// The immutable terminal-configuration source shared by all creation paths.
///
/// The app composition root constructs one long-lived implementation and passes
/// it to each workspace, Dock, and terminal owner. Consumers never read the
/// configuration file themselves, which keeps creation paths nonblocking and
/// prevents multiple caches from diverging.
@MainActor
public protocol DeclarativeTerminalConfigurationProviding: AnyObject {
    /// The latest complete, internally consistent configuration snapshot.
    var snapshot: DeclarativeTerminalConfiguration.Snapshot { get }

    /// The configuration URL represented by ``snapshot``.
    var fileURL: URL { get }

    /// Suspends until the first authoritative snapshot is published.
    func waitForInitialSnapshot() async
}
