import Foundation

/// Path-only filename filter output that can safely cross concurrency domains.
nonisolated struct FileExplorerTreeFilterResult: Sendable {
    let query: String
    let visiblePaths: Set<String>

    static func empty(query: String = "") -> FileExplorerTreeFilterResult {
        FileExplorerTreeFilterResult(query: query, visiblePaths: [])
    }
}
