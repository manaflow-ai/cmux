/// Describes the current user-initiated worktree operation.
enum WorktreeSidebarOperationPhase: Equatable {
    case idle
    case creating
    case inspecting(String)
    case removing(String)
}
