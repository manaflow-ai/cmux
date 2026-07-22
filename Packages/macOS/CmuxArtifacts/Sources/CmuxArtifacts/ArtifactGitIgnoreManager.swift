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
        let commonGitDirectory = commonGitDirectory(for: repository.gitDirectory)
        let infoDirectory = commonGitDirectory.appendingPathComponent("info", isDirectory: true)
        let excludeURL = infoDirectory.appendingPathComponent("exclude", isDirectory: false)
        try fileManager.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.contains(ignoreEntry) else { return }
        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
        updated += ignoreEntry + "\n"
        try updated.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    private func locateGitRepository(startingAt projectRoot: URL) -> (worktreeRoot: URL, gitDirectory: URL)? {
        for current in ArtifactAncestorDirectories(startingAt: projectRoot) {
            if let gitDirectory = resolveGitDirectory(worktreeRoot: current) {
                return (current, gitDirectory)
            }
        }
        return nil
    }

    private func resolveGitDirectory(worktreeRoot: URL) -> URL? {
        let dotGit = worktreeRoot.appendingPathComponent(".git", isDirectory: false)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return dotGit
        }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              contents.lowercased().hasPrefix("gitdir:") else { return nil }
        let rawPath = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: rawPath, relativeTo: worktreeRoot).standardizedFileURL
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func commonGitDirectory(for gitDirectory: URL) -> URL {
        let commonDirectoryFile = gitDirectory.appendingPathComponent("commondir", isDirectory: false)
        guard let rawPath = try? String(contentsOf: commonDirectoryFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return gitDirectory
        }
        let commonDirectory = URL(
            fileURLWithPath: rawPath,
            relativeTo: gitDirectory
        ).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: commonDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return gitDirectory
        }
        return commonDirectory
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
