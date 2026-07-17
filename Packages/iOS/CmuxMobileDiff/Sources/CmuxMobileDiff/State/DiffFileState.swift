internal import CmuxMobileRPC

/// Main-actor-owned mutable state projected into ``DiffFileSnapshot`` values.
struct DiffFileState {
    let file: MobileChangesFile
    var hunks: [MobileChangesHunk]
    var rows: [DiffRowSnapshot]
    var isCollapsed: Bool
    var isViewed: Bool
    var isLoading: Bool
    var loadedPageCount: Int
    var errorMessage: String?

    var snapshot: DiffFileSnapshot {
        DiffFileSnapshot(
            file: file,
            rows: rows,
            isCollapsed: isCollapsed,
            isViewed: isViewed,
            isLoading: isLoading,
            loadedPageCount: loadedPageCount,
            errorMessage: errorMessage
        )
    }
}
