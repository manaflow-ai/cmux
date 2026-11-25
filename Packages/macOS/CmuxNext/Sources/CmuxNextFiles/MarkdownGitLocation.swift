public import Foundation

/// Where a Markdown file sits in its git repository, for the omnibar's repo chip and the Share
/// menu's GitHub link (plans/cmux-next/markdown-omnibar-DESIGN.md section 3).
public struct MarkdownGitLocation: Equatable, Sendable {
    /// The file's state against its branch's upstream.
    public enum State: String, Equatable, Sendable {
        /// Tracked, unchanged, and the same as on the upstream (the GitHub link shows exactly it).
        case pushed
        /// Committed, but the upstream has an older version of it (or the branch has no upstream).
        case unpushed
        /// Edited or staged and not committed.
        case modified
        /// Not tracked.
        case untracked
        /// Ignored by git.
        case ignored
    }

    /// The repository's top folder.
    public var root: String
    /// The file's path inside ``root`` (slash-separated).
    public var relativePath: String
    /// The branch; nil for a detached HEAD.
    public var branch: String?
    /// HEAD's commit; nil before the first commit.
    public var oid: String?
    /// The upstream as git names it (`origin/main`).
    public var upstream: String?
    public var ahead: Int
    /// The `origin` remote's GitHub repository (`owner/repo`), when it is on GitHub.
    public var githubRepository: String?
    public var state: State

    public init(root: String, relativePath: String, branch: String?, oid: String?, upstream: String?, ahead: Int,
                githubRepository: String?, state: State) {
        (self.root, self.relativePath, self.branch, self.oid, self.upstream, self.ahead) = (root, relativePath, branch, oid, upstream, ahead)
        (self.githubRepository, self.state) = (githubRepository, state)
    }

    /// The repository's folder name.
    public var repositoryName: String { (root as NSString).lastPathComponent }

    /// The upstream's branch name on the remote (`origin/team/notes` is `team/notes`).
    public var upstreamBranch: String? {
        guard let upstream, let slash = upstream.firstIndex(of: "/") else { return nil }
        let name = upstream[upstream.index(after: slash)...]
        return name.isEmpty ? nil : String(name)
    }

    /// The file on GitHub at the upstream branch: nil when the file is not committed, the repository
    /// is not on GitHub, or the branch has no upstream.
    public var blobURL: URL? {
        guard state != .untracked, state != .ignored, let githubRepository, let upstreamBranch else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#;")
        let branch = upstreamBranch.addingPercentEncoding(withAllowedCharacters: allowed) ?? upstreamBranch
        let path = relativePath.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
        return URL(string: "https://github.com/\(githubRepository)/blob/\(branch)/\(path.joined(separator: "/"))")
    }

    /// The GitHub link shows exactly what is on disk.
    public var blobIsExact: Bool { state == .pushed && blobURL != nil }

    /// The chip text: `repo · branch` and a state glyph (✓ pushed, ↑N unpushed, ● modified,
    /// ? untracked or ignored); a detached HEAD shows its short commit and no glyph.
    public var chipText: String {
        guard let branch else { return "\(repositoryName) · \(String((oid ?? "HEAD").prefix(7)))" }
        let glyph: String? = switch state {
        case .pushed: upstream == nil ? nil : "✓"
        case .unpushed: ahead > 0 ? "↑\(ahead)" : "↑"
        case .modified: "●"
        case .untracked, .ignored: "?"
        }
        return glyph.map { "\(repositoryName) · \(branch) \($0)" } ?? "\(repositoryName) · \(branch)"
    }
}
