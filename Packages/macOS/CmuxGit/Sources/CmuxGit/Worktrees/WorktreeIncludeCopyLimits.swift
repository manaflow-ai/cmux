/// Resource budgets applied while copying `.worktreeinclude` paths.
struct WorktreeIncludeCopyLimits: Sendable {
    static let production = WorktreeIncludeCopyLimits(
        maximumItemCount: 500_000,
        maximumByteCount: 50 * 1024 * 1024 * 1024,
        freeSpaceReserve: 512 * 1024 * 1024
    )

    let maximumItemCount: Int
    let maximumByteCount: Int64
    let freeSpaceReserve: Int64
}
