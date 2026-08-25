import CmuxArtifacts
import Darwin
import Foundation

extension CMUXCLI {
    func projectFilesProjectRoot(explicitPath: String?) -> URL {
        let start = explicitPath.map(projectFilesURL)
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return ArtifactProjectLocator().projectRoot(startingAt: start, fileManager: .default)
    }

    func projectFilesURL(_ rawPath: String) -> URL {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(
            fileURLWithPath: expanded,
            relativeTo: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        ).standardizedFileURL
    }

    func projectFilesCaptureContext(
        projectRoot: URL,
        environment: [String: String]
    ) throws -> ArtifactCaptureContext {
        let agent = try projectFilesAgentIdentity(environment: environment)
        return ArtifactCaptureContext(
            projectRoot: projectRoot,
            workspaceID: environment["CMUX_WORKSPACE_ID"],
            workspaceTitle: environment["CMUX_WORKSPACE_TITLE"],
            sessionID: agent.sessionID,
            agentName: agent.name
        )
    }

    private func projectFilesAgentIdentity(
        environment: [String: String]
    ) throws -> (sessionID: String?, name: String?) {
        let launchName = canonicalProjectFilesAgentName(
            normalizedProjectFilesEnvironmentValue(environment["CMUX_AGENT_LAUNCH_KIND"])
        )
        let explicitName = launchName
            ?? canonicalProjectFilesAgentName(
                normalizedProjectFilesEnvironmentValue(environment["CMUX_AGENT_NAME"])
            )
        let sessionByAgent: [(name: String, keys: [String])] = [
            ("codex", ["CODEX_THREAD_ID", "CODEX_SESSION_ID", "CMUX_CODEX_SESSION_ID"]),
            ("claude", ["CLAUDE_CODE_SESSION_ID", "CMUX_CLAUDE_SESSION_ID"]),
            ("opencode", ["OPENCODE_SESSION_ID"]),
        ]
        var nativeIdentities: [(sessionID: String, name: String)] = []
        for candidate in sessionByAgent {
            let sessionIDs = candidate.keys.compactMap {
                normalizedProjectFilesEnvironmentValue(environment[$0])
            }
            let uniqueSessionIDs = Set(sessionIDs)
            guard uniqueSessionIDs.count <= 1 else {
                throw ambiguousProjectFilesAgentIdentityError()
            }
            if let sessionID = sessionIDs.first {
                nativeIdentities.append((sessionID: sessionID, name: candidate.name))
            }
        }
        guard nativeIdentities.count <= 1 else {
            throw ambiguousProjectFilesAgentIdentityError()
        }
        if let nativeIdentity = nativeIdentities.first {
            if let launchName,
               launchName != nativeIdentity.name {
                throw ambiguousProjectFilesAgentIdentityError()
            }
            return nativeIdentity
        }
        guard normalizedProjectFilesEnvironmentValue(environment["CMUX_WORKSPACE_ID"]) != nil else {
            throw missingProjectFilesAgentIdentityError()
        }
        return (
            // The generic id is inherited by nested agents and is not bound
            // to the current provider process. A stable workspace identity is
            // required before using this intentional workspace-scoped fallback.
            nil,
            explicitName
        )
    }

    private func normalizedProjectFilesEnvironmentValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func canonicalProjectFilesAgentName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
        return CmuxTaskManagerCodingAgentDefinition.builtIns.first {
            $0.launchKinds.contains(normalized)
        }?.id ?? normalized
    }

    private func ambiguousProjectFilesAgentIdentityError() -> CLIError {
        CLIError(
            message: String(
                localized: "cli.projectFiles.error.ambiguousAgentIdentity",
                defaultValue: "Multiple agent session identities are present; refusing to assign project files to an inherited parent session."
            ),
            exitCode: 2
        )
    }

    private func missingProjectFilesAgentIdentityError() -> CLIError {
        CLIError(
            message: String(
                localized: "cli.projectFiles.error.missingAgentIdentity",
                defaultValue: "A stable agent session or cmux workspace identity is required before writing project files."
            ),
            exitCode: 2
        )
    }

    func openProjectFile(
        path: String,
        allowedRoot: URL? = nil,
        failureMessage: String
    ) throws {
        if let allowedRoot {
            try openConfinedProjectFile(path: path, allowedRoot: allowedRoot, failureMessage: failureMessage)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        process.environment = projectFilesLaunchServicesEnvironment()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError(
                message: ArtifactTerminalTextSanitizer().sanitize(failureMessage)
            )
        }
    }

    private func openConfinedProjectFile(
        path: String,
        allowedRoot: URL,
        failureMessage: String
    ) throws {
        let rootDescriptor = Darwin.open(
            allowedRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard rootDescriptor >= 0,
              let openedRootPath = openedPath(for: rootDescriptor) else {
            if rootDescriptor >= 0 { _ = Darwin.close(rootDescriptor) }
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        defer { _ = Darwin.close(rootDescriptor) }
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              let openedPath = openedPath(for: descriptor),
              isPath(openedPath, insideCanonicalRoot: openedRootPath.path) else {
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        guard status.st_size >= 0, status.st_size <= 64 * 1024 * 1024 else {
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard duplicate >= 0,
              Darwin.lseek(duplicate, 0, SEEK_SET) >= 0 else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        let handle = FileHandle(fileDescriptor: duplicate, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: Int(status.st_size) + 1),
              data.count <= 64 * 1024 * 1024 else {
            _ = Darwin.close(duplicate)
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        _ = Darwin.close(duplicate)
        let systemTemporaryDirectory = FileManager.default.temporaryDirectory
        let temporaryDirectory = systemTemporaryDirectory
            .appendingPathComponent("cmux-project-files", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        // Keep both new copies and legacy root-level copies bounded. The
        // dedicated directory prevents ordinary /tmp entries from being
        // materialized or competing with editor handoffs.
        cleanupTemporaryProjectFiles(in: temporaryDirectory)
        cleanupTemporaryProjectFiles(in: systemTemporaryDirectory)
        let temporaryURL = temporaryDirectory
            .appendingPathComponent("cmux-project-file-\(UUID().uuidString)")
            .appendingPathExtension(openedPath.pathExtension)
        do {
            try data.write(to: temporaryURL, options: .atomic)
        } catch {
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [temporaryURL.path]
        process.environment = projectFilesLaunchServicesEnvironment()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        cleanupTemporaryProjectFiles(in: temporaryDirectory)
        cleanupTemporaryProjectFiles(in: systemTemporaryDirectory)
    }

    private func projectFilesLaunchServicesEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let scrubbedKeys = [
            "CMUX_ALLOW_SOCKET_OVERRIDE",
            "CMUX_SOCKET",
            "CMUX_SOCKET_ENABLE",
            "CMUX_SOCKET_MODE",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_SOCKET_PATH",
            "CMUX_PANEL_ID",
            "CMUX_SURFACE_ID",
            "CMUX_TAB_ID",
            "CMUX_WORKSPACE_ID",
        ]
        for key in scrubbedKeys {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    func cleanupTemporaryProjectFiles(in directory: URL) {
        let maximumFileCount = 256
        let maximumByteCount: Int64 = 256 * 1024 * 1024
        // LaunchServices has no completion callback for the editor that owns
        // this handoff. Treat the age threshold as a lease: fresh copies are
        // never evicted by count/bytes while an editor may still use them.
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }
        let directoryPath = directory.standardizedFileURL.path
        var reclaimable: [(url: URL, size: Int64, modifiedAt: Date)] = []
        for case let entry as URL in enumerator {
            guard entry.deletingLastPathComponent().standardizedFileURL.path == directoryPath,
                  entry.lastPathComponent.hasPrefix("cmux-project-file-") else {
                continue
            }
            var status = stat()
            guard lstat(entry.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size >= 0 else {
                continue
            }
            let modifiedAt = Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec))
            guard modifiedAt < cutoff else {
                // Preserve the active lease even if many editor handoffs are
                // open. A later cleanup after expiry reclaims this copy.
                continue
            }
            reclaimable.append((
                url: entry,
                size: Int64(status.st_size),
                modifiedAt: modifiedAt
            ))
        }
        while reclaimable.count > maximumFileCount {
            guard let oldestIndex = reclaimable.indices.min(by: { lhs, rhs in
                if reclaimable[lhs].modifiedAt != reclaimable[rhs].modifiedAt {
                    return reclaimable[lhs].modifiedAt < reclaimable[rhs].modifiedAt
                }
                return reclaimable[lhs].url.path < reclaimable[rhs].url.path
            }) else {
                break
            }
            _ = unlink(reclaimable.remove(at: oldestIndex).url.path)
        }
        reclaimable.sort {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.url.path > $1.url.path
        }
        var retainedBytes: Int64 = 0
        for entry in reclaimable {
            guard entry.size <= maximumByteCount,
                  retainedBytes <= maximumByteCount - entry.size else {
                _ = unlink(entry.url.path)
                continue
            }
            retainedBytes += entry.size
        }
    }

    private func openedPath(for descriptor: Int32) -> URL? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { bytes in
            fcntl(descriptor, F_GETPATH, bytes.baseAddress)
        }
        guard result == 0 else { return nil }
        return URL(fileURLWithPath: String(
            decoding: buffer.prefix { $0 != 0 },
            as: UTF8.self
        )).resolvingSymlinksInPath().standardizedFileURL
    }

    private func isPath(_ path: URL, insideCanonicalRoot rootPath: String) -> Bool {
        let path = path.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
