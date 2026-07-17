/// Accumulates one record while parsing Git worktree porcelain output.
struct WorktreeSidebarPorcelainRecord {
    var path: String?
    var head: String?
    var branchRef: String?
    var isDetached = false
    var isBare = false
    var isLocked = false
    var lockReason: String?
    var isPrunable = false
    var prunableReason: String?
}
