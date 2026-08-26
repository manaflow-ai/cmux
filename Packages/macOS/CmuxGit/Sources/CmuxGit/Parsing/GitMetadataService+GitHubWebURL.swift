public import Foundation

/// Whether a filesystem path should map to a GitHub blob or tree URL.
public enum GitHubWebURLResource: Sendable {
    /// A file path → `/blob/{branch}/...`.
    case file
    /// A directory path → `/tree/{branch}/...`.
    case folder
}

extension GitMetadataService {
    /// Assembles a github.com blob/tree URL from already-resolved parts.
    ///
    /// - Parameters:
    ///   - slug: GitHub `owner/repo` slug.
    ///   - branch: Current branch name (slashes kept as path segments).
    ///   - relativePathFromWorkTreeRoot: Path relative to the git work tree root.
    ///   - resource: Whether the path is a file (blob) or folder (tree).
    /// - Returns: The github.com URL, or `nil` when slug or branch is empty.
    public nonisolated static func githubWebURL(
        slug: String,
        branch: String,
        relativePathFromWorkTreeRoot: String,
        resource: GitHubWebURLResource
    ) -> URL? {
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSlug.isEmpty, !trimmedBranch.isEmpty else { return nil }

        let kind = resource == .file ? "blob" : "tree"
        let encodedBranch = trimmedBranch
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? String(segment)
            }
            .joined(separator: "/")
        var path = "/\(trimmedSlug)/\(kind)/\(encodedBranch)"
        let relative = relativePathFromWorkTreeRoot
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !relative.isEmpty {
            let encodedSegments = relative
                .split(separator: "/", omittingEmptySubsequences: true)
                .map { segment in
                    String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                        ?? String(segment)
                }
            path += "/" + encodedSegments.joined(separator: "/")
        }
        return URL(string: "https://github.com" + path)
    }

    /// Resolves the enclosing git repo, GitHub slug, and current branch, then
    /// builds a github.com web URL for `path`.
    ///
    /// Returns `nil` when there is no repository, no github.com remote, HEAD is
    /// detached/unreadable, or `path` is outside the work tree.
    ///
    /// - Parameters:
    ///   - path: Absolute filesystem path to a file or folder.
    ///   - resource: Whether the path is a file (blob) or folder (tree).
    /// - Returns: The github.com URL, or `nil` when resolution fails.
    public nonisolated static func githubWebURL(
        forFileSystemPath path: String,
        resource: GitHubWebURLResource
    ) -> URL? {
        // kb:{shortcut}: github.com only — non-github.com remotes omitted
        // kb:{shortcut}: no detached HEAD — detached HEAD gets no item
        guard let repository = resolveGitRepository(containing: path),
              let branch = gitBranchName(repository: repository),
              let remoteOutput = gitRemoteVOutput(repository: repository),
              let slug = githubRepositorySlugs(fromGitRemoteVOutput: remoteOutput).first,
              let relativePath = relativePathFromWorkTreeRoot(
                path: path,
                workTreeRoot: repository.workTreeRoot
              )
        else {
            return nil
        }

        return githubWebURL(
            slug: slug,
            branch: branch,
            relativePathFromWorkTreeRoot: relativePath,
            resource: resource
        )
    }

    /// Path of `path` relative to `workTreeRoot`, or `nil` when not under it.
    nonisolated static func relativePathFromWorkTreeRoot(
        path: String,
        workTreeRoot: String
    ) -> String? {
        let pathURL = URL(fileURLWithPath: path).standardizedFileURL
        let rootURL = URL(fileURLWithPath: workTreeRoot).standardizedFileURL
        let pathString = pathURL.path
        let rootString = rootURL.path

        if pathString == rootString {
            return ""
        }
        let prefix = rootString.hasSuffix("/") ? rootString : rootString + "/"
        guard pathString.hasPrefix(prefix) else { return nil }
        return String(pathString.dropFirst(prefix.count))
    }
}
