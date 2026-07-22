import Foundation

/// Adds the local artifact store to Git's per-checkout exclude file.
struct ArtifactGitIgnoreManager {
    let fileManager: FileManager
    static let ignoreEntry = ".cmux/artifacts/"

    func ensureIgnored(projectRoot: URL) throws {
        guard let repository = locateGitRepository(startingAt: projectRoot) else { return }
        let ignoreEntry = relativeIgnoreEntry(
            projectRoot: projectRoot,
            worktreeRoot: repository.worktreeRoot
        )
        guard let commonGitDirectory = commonGitDirectory(for: repository.gitDirectory) else {
            return
        }
        let infoDirectory = commonGitDirectory.appendingPathComponent("info", isDirectory: true)
        let excludeURL = infoDirectory.appendingPathComponent("exclude", isDirectory: false)
        try fileManager.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
        let existing: String
        if fileManager.fileExists(atPath: excludeURL.path) {
            existing = try String(contentsOf: excludeURL, encoding: .utf8)
        } else {
            existing = ""
        }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.contains(ignoreEntry) else { return }
        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        updated += ignoreEntry + "\n"
        try updated.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    /// Verifies the effective Git view before automatic capture writes any file.
    func permitsAutomaticCapture(
        projectRoot: URL,
        commandRunner: any ArtifactGitCommandRunning
    ) -> Bool {
        guard let repository = locateGitRepository(startingAt: projectRoot) else {
            return !containsGitMarker(startingAt: projectRoot)
        }
        let artifactsRoot = ArtifactStorePaths(projectRoot: projectRoot).artifactsRoot
        guard let relativeArtifactsPath = ArtifactPathResolver().relativePath(
            artifactsRoot,
            root: repository.worktreeRoot
        ) else {
            return false
        }
        let probePath = relativeArtifactsPath + "/.__cmux_probe__"
        guard let ignoreStatus = try? commandRunner.terminationStatus(arguments: [
            "-C", repository.worktreeRoot.path,
            "check-ignore", "--quiet", "--", probePath,
        ]), ignoreStatus == 0 else {
            return false
        }
        guard let trackedStatus = try? commandRunner.terminationStatus(arguments: [
            "-C", repository.worktreeRoot.path,
            "ls-files", "--error-unmatch", "--", relativeArtifactsPath,
        ]) else {
            return false
        }
        return trackedStatus == 1
    }

    private func locateGitRepository(startingAt projectRoot: URL) -> (worktreeRoot: URL, gitDirectory: URL)? {
        for current in ArtifactAncestorDirectories(startingAt: projectRoot) {
            let dotGit = current.appendingPathComponent(".git", isDirectory: false)
            guard fileManager.fileExists(atPath: dotGit.path) else { continue }
            guard let gitDirectory = resolveGitDirectory(worktreeRoot: current) else { return nil }
            return (current, gitDirectory)
        }
        return nil
    }

    private func containsGitMarker(startingAt projectRoot: URL) -> Bool {
        ArtifactAncestorDirectories(startingAt: projectRoot).contains { current in
            fileManager.fileExists(atPath: current.appendingPathComponent(".git").path)
        }
    }

    private func resolveGitDirectory(worktreeRoot: URL) -> URL? {
        let dotGit = worktreeRoot.appendingPathComponent(".git", isDirectory: false)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return isTrustedDirectory(dotGit) ? dotGit.standardizedFileURL : nil
        }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              contents.lowercased().hasPrefix("gitdir:") else { return nil }
        let rawPath = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: rawPath, relativeTo: worktreeRoot).standardizedFileURL
        guard isTrustedDirectory(url),
              isTrustedRedirect(
                gitDirectory: url,
                dotGit: dotGit,
                worktreeRoot: worktreeRoot
              ) else {
            return nil
        }
        return url
    }

    private func commonGitDirectory(for gitDirectory: URL) -> URL? {
        let commonDirectoryFile = gitDirectory.appendingPathComponent("commondir", isDirectory: false)
        guard fileManager.fileExists(atPath: commonDirectoryFile.path) else { return gitDirectory }
        guard let rawPath = try? String(contentsOf: commonDirectoryFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else { return nil }
        let commonDirectory = URL(
            fileURLWithPath: rawPath,
            relativeTo: gitDirectory
        ).standardizedFileURL
        guard isTrustedDirectory(commonDirectory),
              ArtifactPathResolver().relativePath(
                gitDirectory,
                root: commonDirectory
              ) != nil else {
            return nil
        }
        return commonDirectory
    }

    private func isTrustedRedirect(
        gitDirectory: URL,
        dotGit: URL,
        worktreeRoot: URL
    ) -> Bool {
        let backLink = gitDirectory.appendingPathComponent("gitdir", isDirectory: false)
        if let rawPath = try? String(contentsOf: backLink, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            let resolved = URL(fileURLWithPath: rawPath, relativeTo: gitDirectory).standardizedFileURL
            if resolved.path == dotGit.standardizedFileURL.path { return true }
        }

        for ancestor in ArtifactAncestorDirectories(startingAt: worktreeRoot.deletingLastPathComponent()) {
            let ancestorGit = ancestor.appendingPathComponent(".git", isDirectory: true)
            guard isTrustedDirectory(ancestorGit) else { continue }
            if ArtifactPathResolver().relativePath(gitDirectory, root: ancestorGit) != nil {
                return true
            }
        }
        return false
    }

    private func isTrustedDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        return values.isSymbolicLink != true
    }

    private func relativeIgnoreEntry(projectRoot: URL, worktreeRoot: URL) -> String {
        guard let relativePath = ArtifactPathResolver().relativePath(
            projectRoot,
            root: worktreeRoot
        ) else {
            return Self.ignoreEntry
        }
        return escapedGitPattern(relativePath) + "/" + Self.ignoreEntry
    }

    private func escapedGitPattern(_ path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.count)
        for character in path {
            if "\\*?[]#! \t".contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
