import Foundation

/// A Markdown file's location for the omnibar and the Share menu: its absolute path, the `~` form
/// and, inside a git repository, where it sits there (plans/cmux-next/markdown-omnibar-DESIGN.md).
nonisolated struct MarkdownFileLocation: Equatable, Sendable {
    /// The absolute path.
    var path: String
    /// ``path`` with the home folder shortened to `~`.
    var displayPath: String
    /// The repository facts; nil when the file is in no repository or git is missing.
    var git: MarkdownGitLocation?

    /// `path` with a leading `home` folder written `~`; a sibling folder (`/Users/meow` for home
    /// `/Users/me`) and paths outside home stay as they are.
    static func tildePath(_ path: String, home: String) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
