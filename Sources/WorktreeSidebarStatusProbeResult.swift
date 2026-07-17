/// Reports the result of one serialized worktree status probe.
enum WorktreeSidebarStatusProbeResult: Sendable {
    case success(WorktreeSidebarStatus)
    case failure
}
