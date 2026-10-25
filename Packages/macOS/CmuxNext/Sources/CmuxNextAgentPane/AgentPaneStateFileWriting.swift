import Foundation

/// Where the bytes of an agent pane state file go (the chats' scroll places, the new chats'
/// unsent drafts): the disk in the app (``AgentPaneStateFileDiskWriter``), a recorder in tests.
///
/// A failed write or remove is dropped, as the state files always did: each one is a convenience
/// the next settled change writes again.
nonisolated protocol AgentPaneStateFileWriting: Sendable {
    /// Replaces the file at `url` with `data`, atomically.
    func write(_ data: Data, to url: URL)
    /// Removes the file at `url`; a file that is not there is no error.
    func remove(_ url: URL)
}
