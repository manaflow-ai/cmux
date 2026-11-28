/// Window-scope checks for workspace preview snapshots.
extension Collection where Element == MobileWorkspacePreview {
    /// Whether this snapshot is safe to mutate through window-scoped workspace APIs.
    ///
    /// Mobile workspace moves are handled by the Mac window that owns the dragged
    /// workspace. A mixed-window snapshot would compute ordering targets across
    /// rows that the receiving `TabManager` cannot see.
    public var hasSingleKnownWindow: Bool {
        var knownWindowID: String?
        for workspace in self {
            guard let windowID = workspace.windowID, !windowID.isEmpty else {
                return false
            }
            if let knownWindowID {
                guard knownWindowID == windowID else { return false }
            } else {
                knownWindowID = windowID
            }
        }
        return knownWindowID != nil
    }
}
