import Foundation

/// Path-only filename filter output that can safely cross concurrency domains.
nonisolated struct FileExplorerTreeFilterResult: Sendable {
    let query: String
    let rootPaths: [String]
    let childrenByPath: [String: [String]]
    let matchingPaths: Set<String>

    static func empty(query: String = "") -> FileExplorerTreeFilterResult {
        FileExplorerTreeFilterResult(
            query: query,
            rootPaths: [],
            childrenByPath: [:],
            matchingPaths: []
        )
    }
}
