/// Captures the bounded status information used during deletion inspection.
struct WorktreeSidebarDeletionStatusSnapshot {
    var statusFingerprint = WorktreeSidebarGitFingerprint.empty
    var ignoredFingerprint = WorktreeSidebarGitFingerprint.empty
    var hasUncommittedChanges = false
    var hasIgnoredFiles = false
}
