import Foundation

/// One file's `git status --porcelain=v2 --branch --ignored=matching -- <file>`: the branch, its
/// upstream, how far ahead and behind it is, and the file's own state
/// (plans/cmux-next/markdown-omnibar-DESIGN.md section 3).
nonisolated struct MarkdownGitStatus: Equatable, Sendable {
    /// The file's line in the status, or its absence.
    enum FileEntry: Equatable, Sendable {
        /// No line: tracked and unchanged.
        case clean
        /// A changed (`1`), renamed or copied (`2`) or unmerged (`u`) entry, staged or not.
        case modified
        /// `?`: not tracked.
        case untracked
        /// `!`: ignored.
        case ignored
    }

    /// The branch name; nil for a detached HEAD or a branch with no commit.
    var branch: String?
    /// The commit HEAD names; nil before the first commit.
    var oid: String?
    /// The upstream as git names it (`origin/main`); nil when the branch has none.
    var upstream: String?
    var ahead = 0
    var behind = 0
    var file = FileEntry.clean

    /// Parses porcelain v2 output; unknown lines are ignored, so a newer git still parses.
    static func parse(_ text: String) -> MarkdownGitStatus {
        var status = MarkdownGitStatus()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.oid ") {
                let value = String(line.dropFirst("# branch.oid ".count))
                status.oid = value == "(initial)" ? nil : value
            } else if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                status.branch = value == "(detached)" ? nil : value
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                status.file = .modified
            } else if line.hasPrefix("? ") {
                status.file = .untracked
            } else if line.hasPrefix("! ") {
                status.file = .ignored
            }
        }
        return status
    }
}
