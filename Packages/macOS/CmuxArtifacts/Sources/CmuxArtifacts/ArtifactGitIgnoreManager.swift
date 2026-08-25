import Darwin
import Foundation

/// Adds the local artifact store to Git's per-checkout exclude file.
struct ArtifactGitIgnoreManager {
    let fileManager: FileManager
    private static let maximumExcludeBytes: Int64 = 1024 * 1024
    private static let maximumGitMetadataBytes: Int64 = 256 * 1024
    static var ignoreEntries: [String] {
        [".cmux/**"] + ArtifactStorePaths.trackableControlFileNames.map { "!.cmux/\($0)" }
    }

    func ensureIgnored(projectRoot: URL) throws {
        guard let repository = locateGitRepository(startingAt: projectRoot) else {
            if let marker = gitMarker(startingAt: projectRoot) {
                throw ArtifactStoreError.gitPrivacyUnavailable(marker.path)
            }
            return
        }
        let ignoreEntries = try relativeIgnoreEntries(
            projectRoot: projectRoot,
            worktreeRoot: repository.worktreeRoot
        )
        let infoDirectory = repository.commonGitDirectory.appendingPathComponent("info", isDirectory: true)
        let excludeURL = infoDirectory.appendingPathComponent("exclude", isDirectory: false)
        try ensureTrustedDirectory(infoDirectory)
        try rejectUntrustedFileEntry(excludeURL)
        let existing: String
        if fileManager.fileExists(atPath: excludeURL.path) {
            guard let contents = readRegularFile(
                excludeURL,
                allowedRoot: repository.commonGitDirectory,
                maximumBytes: Self.maximumExcludeBytes
            ) else {
                throw ArtifactStoreError.gitPrivacyUnavailable(excludeURL.path)
            }
            existing = contents
        } else {
            existing = ""
        }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let missingEntries = ignoreEntries.filter { !lines.contains($0) }
        guard !missingEntries.isEmpty else { return }
        try ensureTrustedDirectory(infoDirectory)
        try rejectUntrustedFileEntry(excludeURL)
        try append(
            entries: missingEntries,
            to: excludeURL,
            allowedRoot: repository.commonGitDirectory
        )
    }

    /// Resolves the repository context for a fail-closed import validator.
    func writeValidator(
        projectRoot: URL,
        commandRunner: any ArtifactGitCommandRunning
    ) -> ArtifactGitPrivacyValidator? {
        guard let repository = locateGitRepository(startingAt: projectRoot) else {
            guard gitMarker(startingAt: projectRoot) == nil else { return nil }
            return ArtifactGitPrivacyValidator(
                worktreeRoot: nil,
                commandRunner: commandRunner,
                fileManager: fileManager
            )
        }
        return ArtifactGitPrivacyValidator(
            worktreeRoot: repository.worktreeRoot,
            commandRunner: commandRunner,
            fileManager: fileManager
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

    private func gitMarker(startingAt projectRoot: URL) -> URL? {
        for current in ArtifactAncestorDirectories(startingAt: projectRoot) {
            let marker = current.appendingPathComponent(".git", isDirectory: false)
            if filesystemEntryExists(marker) { return marker }
        }
        return nil
    }

    private func resolveGitRepository(worktreeRoot: URL, dotGit: URL) -> ArtifactGitRepository? {
        guard let entryType = try? filesystemEntryType(dotGit) else { return nil }
        if entryType == S_IFDIR {
            let commonDirectoryFile = dotGit.appendingPathComponent("commondir", isDirectory: false)
            guard isTrustedDirectory(dotGit),
                  !filesystemEntryExists(commonDirectoryFile) else {
                return nil
            }
            let gitDirectory = dotGit.standardizedFileURL
            return ArtifactGitRepository(
                worktreeRoot: worktreeRoot,
                gitDirectory: gitDirectory,
                commonGitDirectory: gitDirectory
            )
        }
        guard entryType == S_IFREG,
              let contents = readRegularFile(dotGit, allowedRoot: worktreeRoot),
              contents.lowercased().hasPrefix("gitdir:") else { return nil }
        let rawPath = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: rawPath, relativeTo: worktreeRoot).standardizedFileURL
        guard isTrustedDirectory(url) else {
            return nil
        }
        let commonGitDirectory: URL
        if let linked = linkedCommonGitDirectory(gitDirectory: url, dotGit: dotGit) {
            commonGitDirectory = linked
        } else if isValidatedSubmoduleGitDirectory(
            url,
            worktreeRoot: worktreeRoot
        ) {
            commonGitDirectory = url
        } else {
            return nil
        }
        return ArtifactGitRepository(
            worktreeRoot: worktreeRoot,
            gitDirectory: url,
            commonGitDirectory: commonGitDirectory
        )
    }

    private func linkedCommonGitDirectory(
        gitDirectory: URL,
        dotGit: URL
    ) -> URL? {
        let backLink = gitDirectory.appendingPathComponent("gitdir", isDirectory: false)
        guard let backLinkPath = readRegularFile(backLink, allowedRoot: gitDirectory)?
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
        guard let rawPath = readRegularFile(
            commonDirectoryFile,
            allowedRoot: gitDirectory
        )?
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

    /// Accepts only Git-managed submodule directories under an enclosing repository's
    /// `modules` tree whose `core.worktree` points back to this exact checkout.
    private func isValidatedSubmoduleGitDirectory(
        _ gitDirectory: URL,
        worktreeRoot: URL
    ) -> Bool {
        let parent = worktreeRoot.deletingLastPathComponent().standardizedFileURL
        guard let enclosingRepository = locateGitRepository(startingAt: parent) else {
            return false
        }
        let candidateRoots = [
            enclosingRepository.gitDirectory,
            enclosingRepository.commonGitDirectory,
        ]
        .map { $0.appendingPathComponent("modules", isDirectory: true).standardizedFileURL }
        guard candidateRoots.contains(where: { modulesRoot in
            isTrustedDescendantDirectory(gitDirectory, root: modulesRoot)
        }) else {
            return false
        }
        let config = gitDirectory.appendingPathComponent("config", isDirectory: false)
        guard let configuredWorktree = submoduleWorktree(
            config: config,
            gitDirectory: gitDirectory
        ) else {
            return false
        }
        return configuredWorktree.path == worktreeRoot.standardizedFileURL.path
    }

    private func isTrustedDescendantDirectory(_ candidate: URL, root: URL) -> Bool {
        let candidate = candidate.standardizedFileURL
        let root = root.standardizedFileURL
        guard isTrustedDirectory(root),
              let relativePath = ArtifactPathResolver(fileManager: fileManager)
                  .relativePath(candidate, root: root) else {
            return false
        }
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            guard isTrustedDirectory(current) else { return false }
        }
        return true
    }

    private func submoduleWorktree(config: URL, gitDirectory: URL) -> URL? {
        guard let contents = readRegularFile(config, allowedRoot: gitDirectory) else { return nil }
        var isCoreSection = false
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                isCoreSection = line.caseInsensitiveCompare("[core]") == .orderedSame
                continue
            }
            guard isCoreSection, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.caseInsensitiveCompare("worktree") == .orderedSame else { continue }
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            guard !value.isEmpty else { return nil }
            return URL(
                fileURLWithPath: value,
                relativeTo: gitDirectory
            ).standardizedFileURL
        }
        return nil
    }

    private func readRegularFile(
        _ url: URL,
        allowedRoot: URL,
        maximumBytes: Int64 = Self.maximumGitMetadataBytes
    ) -> String? {
        guard let data = try? ArtifactBoundedFileReader(fileManager: fileManager).data(
            url: url,
            allowedRoot: allowedRoot,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func append(entries: [String], to url: URL, allowedRoot: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ArtifactStoreError.gitPrivacyUnavailable(url.path)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw ArtifactStoreError.gitPrivacyUnavailable(url.path)
        }
        let separator = status.st_size == 0 ? "" : "\n"
        let data = Data((separator + entries.joined(separator: "\n") + "\n").utf8)
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= Self.maximumExcludeBytes - Int64(data.count) else {
            throw ArtifactStoreError.gitPrivacyUnavailable(url.path)
        }
        var descriptorInfo = vnode_fdinfowithpath()
        let pathResult = proc_pidfdinfo(
            Darwin.getpid(),
            descriptor,
            PROC_PIDFDVNODEPATHINFO,
            &descriptorInfo,
            Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        )
        let descriptorPath = withUnsafeBytes(of: &descriptorInfo.pvip.vip_path) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return "" }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
        guard pathResult > 0,
              ArtifactPathResolver(fileManager: fileManager).relativePath(
                URL(fileURLWithPath: descriptorPath),
                root: allowedRoot
              ) != nil else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else {
            throw ArtifactStoreError.gitPrivacyUnavailable(url.path)
        }
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

    private func relativeIgnoreEntries(projectRoot: URL, worktreeRoot: URL) throws -> [String] {
        guard let relativePath = ArtifactPathResolver(fileManager: fileManager).relativePath(
            projectRoot,
            root: worktreeRoot
        ) else {
            return Self.ignoreEntries
        }
        guard !relativePath.unicodeScalars.contains(where: { scalar in
            scalar.value == 0x0A || scalar.value == 0x0D
        }) else {
            throw ArtifactStoreError.gitPrivacyUnavailable(worktreeRoot.path)
        }
        let prefix = escapedGitPattern(relativePath) + "/"
        return Self.ignoreEntries.map { entry in
            guard entry.hasPrefix("!") else { return prefix + entry }
            return "!" + prefix + entry.dropFirst()
        }
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
