package import Foundation

/// Watches folders and everything under them: the seam the Files tree lists
/// itself again through. ``FileTreeWatcher`` in the App, a hand-fired fake in tests.
package nonisolated protocol FileTreeWatching: Sendable {
    /// One value per burst of changes under `folders`. Ending the iteration
    /// (cancelling the task) stops the watch.
    func changes(under folders: [URL]) -> AsyncStream<Void>
}
