extension RightSidebarMode {
    /// Whether the file-explorer store's workspace root should be synced for this
    /// mode. Only the file-backed modes (`files`, `find`) drive the explorer root,
    /// and only while the right sidebar is visible; every other mode keeps the
    /// root lazy so a hidden or non-file panel does not eagerly scan a directory.
    public func shouldSyncFileExplorerStore(isRightSidebarVisible: Bool) -> Bool {
        guard isRightSidebarVisible else { return false }
        switch self {
        case .files, .find:
            return true
        case .sessions, .feed, .dock, .customSidebar:
            return false
        }
    }
}
