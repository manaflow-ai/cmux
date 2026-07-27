public import Foundation

/// Removes profile-owned files and directories from disk.
///
/// Inverts the repository's dependency on `FileManager.default`. The concrete
/// conformer in the app target deletes via a detached utility-priority task,
/// matching the original best-effort, ignore-errors behavior.
public protocol BrowserProfileFileRemoving: Sendable {
    /// Removes the item at the given URL if present, ignoring any error.
    /// - Parameter url: The file or directory to remove.
    func removeItemIfExists(at url: URL) async
}
