import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - claude-teams launch environment
extension CMUXCLI {
    func exportAgentLaunchCommandEnvironment(
        launcher: String,
        executablePath: String,
        arguments: [String],
        workingDirectory: String? = nil
    ) {
        guard !arguments.isEmpty else { return }
        setenv("CMUX_AGENT_LAUNCH_KIND", launcher, 1)
        setenv("CMUX_AGENT_LAUNCH_EXECUTABLE", executablePath, 1)
        setenv("CMUX_AGENT_LAUNCH_ARGV_B64", Self.nulSeparatedBase64(arguments), 1)
        if let workingDirectory,
           !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setenv("CMUX_AGENT_LAUNCH_CWD", workingDirectory, 1)
        } else {
            unsetenv("CMUX_AGENT_LAUNCH_CWD")
        }
    }

    static func nulSeparatedBase64(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    func configureTmuxCompatEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?,
        tmuxPathPrefix: String,
        cmuxBinEnvVar: String,
        termOverrideEnvVar: String,
        extraEnvVars: [(key: String, value: String)] = []
    ) {
        let updatedPath = prependPathEntries(
            [shimDirectory.path],
            to: processEnvironment["PATH"]
        )
        let fakeTmuxValue: String = {
            if let focusedContext {
                let windowToken = focusedContext.windowId ?? focusedContext.workspaceId
                let paneToken = tmuxStableNumericId(focusedContext.paneId ?? focusedContext.paneHandle)
                return "/tmp/\(tmuxPathPrefix)/\(focusedContext.workspaceId),\(windowToken),\(paneToken)"
            }
            return processEnvironment["TMUX"] ?? "/tmp/\(tmuxPathPrefix)/default,0,0"
        }()
        let fakeTmuxPane = focusedContext.map { "%\(tmuxStableNumericId($0.paneId ?? $0.paneHandle))" }
            ?? processEnvironment["TMUX_PANE"]
            ?? "%1"
        let fakeTerm = processEnvironment[termOverrideEnvVar] ?? "screen-256color"

        setenv(cmuxBinEnvVar, executablePath, 1)
        setenv("PATH", updatedPath, 1)
        setenv("TMUX", fakeTmuxValue, 1)
        setenv("TMUX_PANE", fakeTmuxPane, 1)
        setenv("TERM", fakeTerm, 1)
        setenv("CMUX_SOCKET_PATH", socketPath, 1); unsetenv("CMUX_SOCKET")
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setenv("CMUX_SOCKET_PASSWORD", explicitPassword, 1)
        }
        unsetenv("TERM_PROGRAM")
        for envVar in extraEnvVars {
            setenv(envVar.key, envVar.value, 1)
        }
        if let focusedContext {
            // The launcher's OWN surface (its inherited env, passed in as processEnvironment) is the
            // agent's canonical identity; the focused pane is only a fallback. Stamping the focused
            // pane here would desync CMUX_SURFACE_ID from the inherited CMUX_PANEL_ID and make agents
            // (codex omx/teams) record + restore into the wrong surface after reload (#4920).
            let identity = AgentSpawnIdentity().resolve(
                ownWorkspaceId: processEnvironment["CMUX_WORKSPACE_ID"],
                ownSurfaceId: processEnvironment["CMUX_SURFACE_ID"],
                focusedWorkspaceId: focusedContext.workspaceId,
                focusedSurfaceId: focusedContext.surfaceId
            )
            if let workspaceId = identity.workspaceId {
                setenv("CMUX_WORKSPACE_ID", workspaceId, 1)
            }
            if let surfaceId = identity.surfaceId {
                setenv("CMUX_SURFACE_ID", surfaceId, 1)
            }
        }
    }

    /// Hidden `__debug-tmux-compat-env` seam: runs the real ``configureTmuxCompatEnvironment`` against
    /// the live socket's focused context and prints the resolved CMUX_* identity, so an integration
    /// test can assert the launcher stamps the launch surface (its own env) rather than the focused
    /// pane (#4920). Not user-facing. The shim/tmux params here do not affect the id resolution.
    func debugDumpTmuxCompatEnvironment(socketPath: String, explicitPassword: String?) throws {
        var processEnvironment = ProcessInfo.processInfo.environment
        // Resolve the focused context from the SAME socket this command was pointed at, not whatever
        // CMUX_SOCKET_PATH the process happened to inherit.
        processEnvironment["CMUX_SOCKET_PATH"] = socketPath
        let focusedContext = try tmuxCompatFocusedContext(
            processEnvironment: processEnvironment,
            explicitPassword: explicitPassword
        )
        let shimDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-debug-tmux-shim-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        // This is the one-shot debug dump (it never spawns a long-lived agent that would need the
        // shims on PATH), so remove the shim dir on exit instead of leaking a /tmp dir per invocation.
        defer { try? FileManager.default.removeItem(at: shimDirectory) }
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: processEnvironment["CMUX_BUNDLED_CLI_PATH"] ?? "cmux",
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: "cmux-debug",
            cmuxBinEnvVar: "CMUX_BIN",
            termOverrideEnvVar: "TERM"
        )
        func dump(_ key: String) -> String { getenv(key).map { String(cString: $0) } ?? "" }
        print("CMUX_WORKSPACE_ID=\(dump("CMUX_WORKSPACE_ID"))")
        print("CMUX_SURFACE_ID=\(dump("CMUX_SURFACE_ID"))")
        print("CMUX_PANEL_ID=\(dump("CMUX_PANEL_ID"))")
        print("CMUX_TAB_ID=\(dump("CMUX_TAB_ID"))")
    }

    private static let claudeNodeOptionsRestoreModule = """
    const hadOriginalNodeOptions = process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT === "1";
    if (hadOriginalNodeOptions) {
        process.env.NODE_OPTIONS = process.env.CMUX_ORIGINAL_NODE_OPTIONS ?? "";
    } else {
        delete process.env.NODE_OPTIONS;
    }
    delete process.env.CMUX_ORIGINAL_NODE_OPTIONS;
    delete process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT;
    """

    private func configureClaudeTeamsEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?
    ) {
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: "cmux-claude-teams",
            cmuxBinEnvVar: "CMUX_CLAUDE_TEAMS_CMUX_BIN",
            termOverrideEnvVar: "CMUX_CLAUDE_TEAMS_TERM",
            extraEnvVars: [
                (key: "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", value: "1"),
            ]
        )
        guard let restoreModuleURL = try? createClaudeNodeOptionsRestoreModule() else {
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT")
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS")
            return
        }
        if let existing = processEnvironment["NODE_OPTIONS"] {
            setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "1", 1)
            setenv("CMUX_ORIGINAL_NODE_OPTIONS", normalizedNodeOptionsForRestore(existing), 1)
        } else {
            setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "0", 1)
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS")
        }
        setenv(
            "NODE_OPTIONS",
            mergedNodeOptions(
                existing: processEnvironment["NODE_OPTIONS"],
                restoreModulePath: restoreModuleURL.path
            ),
            1
        )
    }

    func createTmuxCompatShimDirectory(
        directoryName: String,
        tmuxShimScript: String
    ) throws -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let root = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let tmuxURL = root.appendingPathComponent("tmux", isDirectory: false)
        try writeShimIfChanged(tmuxShimScript, to: tmuxURL)
        return root
    }

    private func createClaudeTeamsShimDirectory() throws -> URL {
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        exec "${CMUX_CLAUDE_TEAMS_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        return try createTmuxCompatShimDirectory(
            directoryName: "claude-teams-bin",
            tmuxShimScript: script
        )
    }

    func createClaudeNodeOptionsRestoreModule() throws -> URL {
        let rawTemporaryDirectory = ProcessInfo.processInfo.environment["TMPDIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let temporaryDirectory: String
        if let rawTemporaryDirectory, !rawTemporaryDirectory.isEmpty {
            temporaryDirectory = rawTemporaryDirectory
        } else {
            temporaryDirectory = NSTemporaryDirectory()
        }
        let root = URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
            .appendingPathComponent("cmux-claude-node-options", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let restoreModuleURL = root.appendingPathComponent("restore-node-options.cjs", isDirectory: false)
        try writeShimIfChanged(Self.claudeNodeOptionsRestoreModule, to: restoreModuleURL)
        return restoreModuleURL
    }

    func runClaudeTeams(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath; launcherEnvironment.removeValue(forKey: "CMUX_SOCKET")
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }
        let shimDirectory = try createClaudeTeamsShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = try tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        // Check custom path from Settings > Automation > Claude Code first.
        // Never fall back to a cmux-bundled provider binary.
        guard let claudeExecutablePath = resolveClaudeExecutable(
            configuredCandidates: [
                launcherEnvironment["CMUX_CUSTOM_CLAUDE_PATH"],
                UserDefaults.standard.string(forKey: "claudeCodeCustomClaudePath"),
            ],
            searchPath: launcherEnvironment["PATH"]
        ) else {
            throw CLIError(message: missingProviderExecutableMessage(
                displayName: "Claude Code",
                executableName: "claude"
            ))
        }
        launcherEnvironment["PATH"] = providerExecutableSearchPath(
            searchPath: launcherEnvironment["PATH"],
            includingExecutableAt: claudeExecutablePath
        )
        configureClaudeTeamsEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext
        )

        let launchPath = claudeExecutablePath
        let launchArguments = claudeTeamsLaunchArguments(commandArgs: commandArgs)
        exportAgentLaunchCommandEnvironment(
            launcher: "claudeTeams",
            executablePath: executablePath,
            arguments: [executablePath, "claude-teams"] + launchArguments,
            workingDirectory: launcherEnvironment["PWD"]
        )
        var argv = ([launchPath] + launchArguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        execv(launchPath, &argv)
        let code = errno
        throw CLIError(message: "Failed to launch claude: \(String(cString: strerror(code)))")
    }

    // MARK: - cmux codex-teams

}
