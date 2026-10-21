import Foundation
@testable import CmuxNextFiles

/// A watcher that never reports a change (tests list again by hand).
struct NeverWatcher: FolderWatching {
    func changes(in folder: URL) -> AsyncStream<FolderChange> { AsyncStream { _ in } }
}
