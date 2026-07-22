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
        let infoDirectory = repository.commonGitDirectory.appendingPathComponent("info", isDirectory: true)
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

    private func locateGitRepository(startingAt projectRoot: URL) -> ArtifactGitRepository? {
        for current in ArtifactAncestorDirectories(startingAt: projectRoot) {
            let dotGit = current.appendingPathComponent(".git", isDirectory: false)
            guard filesystemEntryExists(dotGit) else { continue }
            return resolveGitRepository(worktreeRoot: current, dotGit: dotGit)
        }
        return nil
    }

    private func containsGitMarker(startingAt projectRoot: URL) -> Bool {
        ArtifactAncestorDirectories(startingAt: projectRoot).contains { current in
            filesystemEntryExists(current.appendingPathComponent(".git"))
        }
    }

    private func resolveGitRepository(worktreeRoot: URL, dotGit: URL) -> ArtifactGitRepository? {
        guard let entryType = try? filesystemEntryType(dotGit) else { return nil }
        if entryType == S_IFDIR {
            let commonDirectoryFile = dotGit.appendingPathComponent("commondir", isDirectory: false)
            guard isTrustedDirectory(dotGit), !filesystemEntryExists(commonDirectoryFile) else {
                return nil
            }
            let gitDirectory = dotGit.standardizedFileURL
            return ArtifactGitRepository(
                worktreeRoot: worktreeRoot,
                commonGitDirectory: gitDirectory
            )
        }
        guard entryType == S_IFREG,
              let contents = readRegularFile(dotGit),
              contents.lowercased().hasPrefix("gitdir:") else { return nil }
        let rawPath = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: rawPath, relativeTo: worktreeRoot).standardizedFileURL
        guard isTrustedDirectory(url),
              let commonGitDirectory = linkedCommonGitDirectory(
                gitDirectory: url,
                dotGit: dotGit
              ) else {
            return nil
        }
        return ArtifactGitRepository(
            worktreeRoot: worktreeRoot,
            commonGitDirectory: commonGitDirectory
        )
    }

    private func linkedCommonGitDirectory(
        gitDirectory: URL,
        dotGit: URL
    ) -> URL? {
        let backLink = gitDirectory.appendingPathComponent("gitdir", isDirectory: false)
        guard let backLinkPath = readRegularFile(backLink)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !backLinkPath.isEmpty else {
            return nil
        }
        let resolvedBackLink = URL(
            fileURLWithPath: backLinkPath,
            relativeTo: gitDirectory
        ).standardizedFileURL
        guard resolvedBackLink.path == dotGit.standardizedFileURL.path else { return nil }

        let commonDirectoryFile = gitDirectory.appendingPathComponent("commondir", isDirectory: false)
        guard let rawPath = readRegularFile(commonDirectoryFile)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        let commonDirectory = URL(
            fileURLWithPath: rawPath,
            relativeTo: gitDirectory
        ).standardizedFileURL
        let worktreesDirectory = gitDirectory.deletingLastPathComponent().standardizedFileURL
        guard worktreesDirectory.lastPathComponent == "worktrees",
              worktreesDirectory.deletingLastPathComponent().standardizedFileURL.path
                == commonDirectory.path,
              isTrustedDirectory(commonDirectory) else {
            return nil
        }
        return commonDirectory
    }

    private func readRegularFile(_ url: URL) -> String? {
        guard (try? filesystemEntryType(url)) == S_IFREG else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func filesystemEntryExists(_ url: URL) -> Bool {
        do {
            return try filesystemEntryType(url) != nil
        } catch {
            return true
        }
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
