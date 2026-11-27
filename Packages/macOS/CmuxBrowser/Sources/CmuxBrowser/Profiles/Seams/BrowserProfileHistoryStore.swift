import Foundation

/// A per-profile browsing-history store handle, as seen by profile management.
///
/// The concrete conformer in the app target wraps `BrowserHistoryStore`. The
/// repository only needs the lifecycle operations it invokes during delete and
/// clear; navigation and query APIs stay out of this seam.
@MainActor
public protocol BrowserProfileHistoryStore: AnyObject {
    /// Clears in-memory history entries without first reading the persisted file.
    func clearHistoryWithoutLoadingPersistedFile()
    /// Cancels any debounced pending saves for this profile's history file.
    func cancelPendingSaves()
    /// Flushes any pending saves for this profile's history file synchronously.
    func flushPendingSaves()
}
