import Foundation

extension GitMetadataService {
    /// Walks upward from `directory` to the nearest enclosing git repository.
    ///
    /// Handles a `.git` directory, a `.git` *file* (`gitdir:` pointer used by
    /// linked worktrees and submodules), and the shared `commondir`.
    ///
    /// - Parameter directory: An absolute path to start from. A path to a file
    ///   is treated as its containing directory.
    /// - Returns: The resolved repository, or `nil` if the filesystem root is
    ///   reached without finding one.
    nonisolated static func resolveGitRepository(containing directory: String) -> ResolvedGitRepository? {
        let startURL = URL(fileURLWithPath: directory).standardizedFileURL
        let fileManager = FileManager.default
        var currentURL = startURL
        var isDirectory: ObjCBool = false

        if !fileManager.fileExists(atPath: currentURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            currentURL.deleteLastPathComponent()
        }

        while true {
            let dotGitURL = currentURL.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) {
                let gitDirectory: String?
                if isDirectory.boolValue {
                    gitDirectory = dotGitURL.standardizedFileURL.path
                } else {
                    gitDirectory = gitDirectoryFromDotGitFile(dotGitURL, relativeTo: currentURL)
                }

                if let gitDirectory {
                    let commonDirectory = gitCommonDirectory(gitDirectory: gitDirectory)
                    return ResolvedGitRepository(
                        workTreeRoot: currentURL.standardizedFileURL.path,
                        gitDirectory: gitDirectory,
                        commonDirectory: commonDirectory
                    )
                }
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if shouldStopGitRepositorySearch(currentURL: currentURL, parentURL: parentURL) {
                return nil
            }
            currentURL = parentURL
        }
    }

    /// Whether the upward repository search should stop at `currentURL`.
    ///
    /// Stops at the filesystem root, or when the parent no longer differs from
    /// the current directory (so the walk cannot loop forever).
    nonisolated static func shouldStopGitRepositorySearch(currentURL: URL, parentURL: URL) -> Bool {
        if parentURL.path == currentURL.path {
            return true
        }

        let standardizedCurrentPath = currentURL.standardizedFileURL.path
        if standardizedCurrentPath == "/" {
            return true
        }

        return parentURL.standardizedFileURL.path == standardizedCurrentPath
    }

    /// Resolves the git directory a `.git` *file* points at via its `gitdir:`
    /// line, relative to the work-tree root when the path is relative.
    nonisolated static func gitDirectoryFromDotGitFile(
        _ dotGitURL: URL,
        relativeTo workTreeRootURL: URL
    ) -> String? {
        guard let contents = try? String(contentsOf: dotGitURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir:"
        guard trimmed.lowercased().hasPrefix(prefix) else {
            return nil
        }

        let rawPath = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: String(rawPath)).standardizedFileURL.path
        }
        return workTreeRootURL
            .appendingPathComponent(String(rawPath))
            .standardizedFileURL
            .path
    }

    /// Resolves the shared common directory for `gitDirectory` by reading its
    /// `commondir` file, falling back to `gitDirectory` itself.
    nonisolated static func gitCommonDirectory(gitDirectory: String) -> String {
        let gitDirectoryURL = URL(fileURLWithPath: gitDirectory)
        let commonDirURL = gitDirectoryURL.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commonDirURL, encoding: .utf8) else {
            return gitDirectory
        }

        let rawPath = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return gitDirectory }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL.path
        }
        return gitDirectoryURL
            .appendingPathComponent(rawPath)
            .standardizedFileURL
            .path
    }
}
