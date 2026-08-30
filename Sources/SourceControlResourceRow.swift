import Foundation

/// A filesystem-free row snapshot rendered by the Source Control list.
struct SourceControlResourceRow: Identifiable, Hashable, Sendable {
    let path: String
    let relativePath: String
    let status: GitFileStatus

    var id: String { path }

    var group: SourceControlGroup {
        status == .untracked ? .untracked : .changes
    }

    var statusLetter: String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        }
    }
}
