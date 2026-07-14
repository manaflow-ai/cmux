/// The authoritative outcome after Git removes or prunes a worktree registration.
struct WorktreeSidebarDeletionResult: Equatable, Sendable {
    enum Removal: Equatable, Sendable {
        case removed
        case pruned
    }

    enum Branch: Equatable, Sendable {
        case deleted(String)
        case preserved(String, reason: String)
        case notApplicable
    }

    let removal: Removal
    let branch: Branch
}
