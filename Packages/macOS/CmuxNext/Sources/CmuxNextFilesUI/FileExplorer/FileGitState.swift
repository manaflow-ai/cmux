package import Foundation

/// An item's git state in the Files tree, from `git status --porcelain=v1 -z`
/// (the letters VS Code's explorer shows).
package nonisolated enum FileGitState: String, Equatable, Sendable {
    case modified, added, deleted, renamed, untracked, conflicted
    /// A folder with a changed item somewhere inside.
    case containsChanges

    /// The letter the row shows.
    package var badge: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .conflicted: "!"
        case .containsChanges: "•"
        }
    }

    /// Each changed path (relative to the repository's top) and its state. A rename's second
    /// field (its old path) is skipped; ignored items (`!!`) are left out.
    package static func parse(_ porcelain: String) -> [String: FileGitState] {
        var states: [String: FileGitState] = [:]
        var fields = porcelain.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let x = field[field.startIndex], y = field[field.index(after: field.startIndex)]
            let path = String(field.dropFirst(3))
            if x == "R" || x == "C" { _ = fields.next() }
            guard let state = state(x, y) else { continue }
            states[path] = state
        }
        return states
    }

    private static func state(_ x: Character, _ y: Character) -> FileGitState? {
        switch (x, y) {
        case ("?", "?"): .untracked
        case ("!", "!"): nil
        case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): .conflicted
        case ("R", _), (_, "R"): .renamed
        case ("A", _): .added
        case ("D", _), (_, "D"): .deleted
        default: .modified
        }
    }
}
