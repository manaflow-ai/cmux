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
        return (
            normalizedProjectFilesEnvironmentValue(environment["CMUX_AGENT_SESSION_ID"]),
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
              isPath(openedPath, inside: allowedRoot) else {
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
        let temporaryURL = FileManager.default.temporaryDirectory
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

    private func isPath(_ path: URL, inside root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = path.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
