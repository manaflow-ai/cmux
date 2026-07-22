import Darwin
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
        try ensureTrustedDirectory(infoDirectory)
        try rejectUntrustedFileEntry(excludeURL)
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
        try ensureTrustedDirectory(infoDirectory)
        try rejectUntrustedFileEntry(excludeURL)
        try updated.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    /// Resolves the repository context for a fail-closed automatic import validator.
    func automaticWriteValidator(
        projectRoot: URL,
        commandRunner: any ArtifactGitCommandRunning
    ) -> ArtifactGitPrivacyValidator? {
        guard let repository = locateGitRepository(startingAt: projectRoot) else {
            guard !containsGitMarker(startingAt: projectRoot) else { return nil }
            return ArtifactGitPrivacyValidator(worktreeRoot: nil, commandRunner: commandRunner)
        }
        return ArtifactGitPrivacyValidator(
            worktreeRoot: repository.worktreeRoot,
            commandRunner: commandRunner
        )
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

    private func ensureTrustedDirectory(_ url: URL) throws {
        let entryType = try filesystemEntryType(url)
        if entryType == nil {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } else if entryType != S_IFDIR {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
        guard try filesystemEntryType(url) == S_IFDIR else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
    }

    private func rejectUntrustedFileEntry(_ url: URL) throws {
        guard let entryType = try filesystemEntryType(url) else { return }
        guard entryType == S_IFREG else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
    }

    private func filesystemEntryType(_ url: URL) throws -> mode_t? {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return status.st_mode & S_IFMT
        }
        guard errno == ENOENT else {
            throw CocoaError(.fileReadUnknown)
        }
        return nil
    }
}
