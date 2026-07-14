import Foundation

/// Independent query state for the unified explorer's two scopes.
struct FileExplorerSearchQueryState: Equatable, Sendable {
    private(set) var namesQuery = ""
    private(set) var contentsQuery = ""

    func query(for scope: FileExplorerSearchScope) -> String {
        switch scope {
        case .names: namesQuery
        case .contents: contentsQuery
        }
    }

    mutating func setQuery(_ query: String, for scope: FileExplorerSearchScope) {
        switch scope {
        case .names:
            namesQuery = query
        case .contents:
            contentsQuery = query
        }
    }

    mutating func clearQueries() {
        namesQuery = ""
        contentsQuery = ""
    }
}
