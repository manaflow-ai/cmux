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
        if let genericSessionID = normalizedProjectFilesEnvironmentValue(
            environment["CMUX_AGENT_SESSION_ID"]
        ) {
            let genericName = canonicalProjectFilesAgentName(
                normalizedProjectFilesEnvironmentValue(environment["CMUX_AGENT_NAME"])
            ) ?? launchName
            // `CMUX_AGENT_*` is inherited by nested processes and can still
            // describe the parent agent. A provider-native identity is the
            // authoritative child identity; never reject it because the
            // inherited generic fallback differs. Use the generic pair only
            // when no native provider identity was supplied.
            if nativeIdentities.isEmpty {
                nativeIdentities.append((
                    sessionID: genericSessionID,
                    name: genericName ?? "agent"
                ))
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
        throw missingProjectFilesAgentIdentityError()
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
                defaultValue: "A stable agent session identity is required before writing project files."
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
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try openPrivateProjectFilesDirectory(temporaryDirectory)
        } catch {
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        // Keep both new copies and legacy root-level copies bounded. The
        // dedicated directory prevents ordinary /tmp entries from being
        // materialized or competing with editor handoffs.
        guard cleanupTemporaryProjectFiles(
            in: temporaryDirectory,
            reservingBytes: Int64(data.count),
            reservingFileCount: 1
        ) else {
            throw CLIError(
                message: String(
                    localized: "cli.projectFiles.error.tooManyOpenCopies",
                    defaultValue: "Too many project files are already open; close one and try again."
                ),
                exitCode: 2
            )
        }
        cleanupTemporaryProjectFiles(in: systemTemporaryDirectory)
        let temporaryName = "cmux-project-file-\(UUID().uuidString)"
            + (openedPath.pathExtension.isEmpty ? "" : ".\(openedPath.pathExtension)")
        let temporaryURL = temporaryDirectory.appendingPathComponent(temporaryName)
        let outputDescriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard outputDescriptor >= 0 else {
            throw CLIError(message: ArtifactTerminalTextSanitizer().sanitize(failureMessage))
        }
        do {
            let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false)
            try output.write(contentsOf: data)
            try output.close()
        } catch {
            _ = Darwin.close(outputDescriptor)
            _ = Darwin.unlink(temporaryURL.path)
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

    private func openPrivateProjectFilesDirectory(_ directory: URL) throws -> Int32 {
        if mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
            throw CocoaError(.fileWriteUnknown)
        }
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var status = stat()
        guard lstat(directory.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              fchmod(descriptor, S_IRWXU) == 0 else {
            _ = Darwin.close(descriptor)
            throw CocoaError(.fileWriteNoPermission)
        }
        return descriptor
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

    @discardableResult
    func cleanupTemporaryProjectFiles(
        in directory: URL,
        reservingBytes: Int64 = 0,
        reservingFileCount: Int = 0
    ) -> Bool {
        ProjectFileTemporaryCopyCleaner().cleanup(
            in: directory,
            reservingBytes: reservingBytes,
            reservingFileCount: reservingFileCount
        )
    }

    private func openedPath(for descriptor: Int32) -> URL? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.fcntl(descriptor, F_GETPATH, baseAddress)
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
