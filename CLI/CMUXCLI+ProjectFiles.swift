import CmuxArtifacts
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
        let launchName = normalizedProjectFilesEnvironmentValue(
            environment["CMUX_AGENT_LAUNCH_KIND"]
        )?.lowercased()
        let explicitName = launchName
            ?? normalizedProjectFilesEnvironmentValue(environment["CMUX_AGENT_NAME"])?.lowercased()
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
            let supportedLaunchNames = Set(sessionByAgent.map(\.name))
            if let launchName,
               supportedLaunchNames.contains(launchName),
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

    private func ambiguousProjectFilesAgentIdentityError() -> CLIError {
        CLIError(
            message: String(
                localized: "cli.projectFiles.error.ambiguousAgentIdentity",
                defaultValue: "Multiple agent session identities are present; refusing to assign project files to an inherited parent session."
            ),
            exitCode: 2
        )
    }

    func openProjectFile(path: String, failureMessage: String) throws {
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
}
