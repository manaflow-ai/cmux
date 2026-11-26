/// Produces change notifications for a set of Ghostty config paths.
///
/// The production conformer is ``FileWatcherGhosttyConfigChangeSource``; tests
/// inject a source whose events they yield by hand.
public protocol GhosttyConfigChangeSource: Sendable {
    /// Starts watching `paths` and returns the subscription.
    ///
    /// Paths need not exist yet. The subscription must keep reporting changes
    /// after an editor replaces a file by renaming a new one over it.
    ///
    /// - Parameter paths: Absolute file paths to watch.
    /// - Returns: The live subscription; cancel it before dropping it.
    func subscribe(toPaths paths: [String]) async -> GhosttyConfigChangeSubscription
}
