import CMUXAgentLaunch
import Foundation

/// Mobile "compose a prompt → launch an agent workspace" RPCs
/// (capability `workspace.launch_agent.v1`):
///
/// - `mobile.agent.launch_options` reports which coding agents are installed on
///   this Mac and which working directories make sense for a new agent
///   workspace, so the iOS composer only offers launches that will succeed.
/// - `mobile.workspace.launch_agent` creates a workspace, types the agent
///   command with the composed prompt at its fresh shell (Ghostty
///   `initial_input`, so the agent inherits the user's login-shell
///   environment), records the prompt as the workspace's submitted message,
///   and returns the same workspace-list payload as `workspace.create` so the
///   phone lands directly in the new workspace.
extension TerminalController {
    /// Providers the composer can launch with a positional prompt argument.
    /// `opencode`'s interactive TUI has no equivalent prompt argv, so it stays
    /// out until it does.
    static let mobilePromptLaunchableProviders: [AgentSessionProviderID] = [.claude, .codex]

    func v2MobileAgentLaunchOptions(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        let resolver = AgentExecutableResolver(
            configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        )
        let agents: [[String: Any]] = Self.mobilePromptLaunchableProviders.map { provider in
            [
                "id": provider.rawValue,
                "name": provider.displayName,
                "installed": (try? resolver.resolve(provider)) != nil,
            ]
        }
        let (defaultDirectory, workspaceDirectories) = v2MainSync {
            (
                tabManager.implicitWorkingDirectoryForNewWorkspace(from: tabManager.selectedWorkspace),
                tabManager.tabs.map(\.currentDirectory)
            )
        }
        var seen = Set<String>()
        var directories: [[String: Any]] = []
        for path in [defaultDirectory].compactMap({ $0 }) + workspaceDirectories {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            directories.append(["path": trimmed])
        }
        return .ok([
            "agents": agents,
            "directories": directories,
            "default_directory": v2OrNull(defaultDirectory),
        ])
    }

    func v2MobileWorkspaceLaunchAgent(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        guard let prompt = v2RawString(params, "prompt")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            return .err(code: "invalid_params", message: "prompt is required", data: nil)
        }
        let agentRaw = v2RawString(params, "agent")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider: AgentSessionProviderID
        if let agentRaw, !agentRaw.isEmpty {
            guard let parsed = AgentSessionProviderID(rawValue: agentRaw),
                  Self.mobilePromptLaunchableProviders.contains(parsed) else {
                return .err(code: "invalid_params", message: "Unknown agent", data: ["agent": agentRaw])
            }
            provider = parsed
        } else {
            provider = .claude
        }
        let resolver = AgentExecutableResolver(
            configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        )
        guard let plan = try? resolver.resolve(provider) else {
            return .err(
                code: "not_found",
                message: "\(provider.executableName) is not installed on this Mac",
                data: ["agent": provider.rawValue]
            )
        }

        let command = AgentPromptWorkspaceLaunch.shellCommand(
            executablePath: plan.executableURL.path,
            prompt: prompt
        )
        let startupInput: String
        switch AgentPromptWorkspaceLaunch.startupInput(command: command) {
        case let .inline(line):
            startupInput = line
        case let .script(body):
            guard let scriptURL = Self.writeMobileAgentLaunchScript(body: body) else {
                return .err(code: "internal_error", message: "Could not stage the launch script", data: nil)
            }
            startupInput = AgentPromptWorkspaceLaunch.scriptInvocation(scriptPath: scriptURL.path)
        }

        var createParams = params
        // Never allow raw argv through this method; the composed shell line is
        // the only launch vehicle.
        createParams.removeValue(forKey: "initial_command")
        createParams["initial_input"] = startupInput
        if v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            createParams["title"] = AgentPromptWorkspaceLaunch.derivedWorkspaceTitle(prompt: prompt)
        }
        createParams["focus"] = false
        // The whole point of the launch is that the agent starts working now,
        // before (and regardless of whether) the phone attaches to the terminal.
        createParams["eager_load_terminal"] = true
        createParams["auto_refresh_metadata"] = false
        let createResult = v2WorkspaceCreate(params: createParams, tabManager: tabManager)
        guard case let .ok(payload) = createResult else {
            return createResult
        }
        let createdWorkspaceID = (payload as? [String: Any])?["workspace_id"] as? String
        if let createdWorkspaceID, let workspaceUUID = UUID(uuidString: createdWorkspaceID) {
            v2MainSync {
                _ = tabManager.handlePromptSubmit(workspaceId: workspaceUUID, message: prompt)
            }
            createParams["workspace_id"] = createdWorkspaceID
        }
        return v2MobileWorkspaceList(
            params: createParams,
            tabManager: tabManager,
            createdWorkspaceID: createdWorkspaceID
        )
    }

    /// Stages an oversized/multiline launch command as a private launcher
    /// script (same discipline as the agent fork/resume path). Scripts older
    /// than a day are pruned opportunistically.
    private static func writeMobileAgentLaunchScript(
        body: String,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent("cmux-agent-launch", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneMobileAgentLaunchScripts(in: directoryURL, fileManager: fileManager)
            let scriptURL = directoryURL.appendingPathComponent("launch-\(UUID().uuidString).zsh")
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func pruneMobileAgentLaunchScripts(in directoryURL: URL, fileManager: FileManager) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let contents = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
