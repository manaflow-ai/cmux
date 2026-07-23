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
    ) -> ArtifactCaptureContext {
        let agent = projectFilesAgentIdentity(environment: environment)
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
    ) -> (sessionID: String?, name: String?) {
        let explicitName = (
            normalizedProjectFilesEnvironmentValue(environment["CMUX_AGENT_LAUNCH_KIND"])
                ?? normalizedProjectFilesEnvironmentValue(environment["CMUX_AGENT_NAME"])
        )?.lowercased()
        let sessionByAgent: [(name: String, keys: [String])] = [
            ("codex", ["CODEX_THREAD_ID", "CODEX_SESSION_ID", "CMUX_CODEX_SESSION_ID"]),
            ("claude", ["CLAUDE_CODE_SESSION_ID", "CMUX_CLAUDE_SESSION_ID"]),
            ("opencode", ["OPENCODE_SESSION_ID"]),
        ]
        if let explicitName,
           let selected = sessionByAgent.first(where: { $0.name == explicitName }),
           let sessionID = selected.keys.lazy.compactMap({
               normalizedProjectFilesEnvironmentValue(environment[$0])
           }).first {
            return (sessionID, selected.name)
        }
        for candidate in sessionByAgent {
            if let sessionID = candidate.keys.lazy.compactMap({
                normalizedProjectFilesEnvironmentValue(environment[$0])
            }).first {
                return (sessionID, candidate.name)
            }
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
