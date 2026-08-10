public import CmuxTerminalCore
public import Foundation
internal import CMUXAgentLaunch
internal import Darwin

/// Resolves one authoritative terminal launch for either process ownership model.
@MainActor
public final class TerminalSurfaceLaunchResolver {
    public typealias DefaultShellArguments = @Sendable () -> [String]

    private let userGhosttyShellIntegrationMode: @MainActor () -> String
    private let spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding
    private let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem
    private let sessionPortBase: Int
    private let sessionPortRangeSize: Int
    private let resourceURL: URL?
    private let bundleIdentifier: String?
    private let ambientEnvironment: [String: String]
    private let defaultShellArguments: DefaultShellArguments
    private let resolvedUserShell: @MainActor () -> String?
    private let agentCommandShimInstallDeadline: Duration
    private let agentCommandShimInstallDeadlineClock: any Clock<Duration>

    public convenience init(
        dependencies: TerminalSurfaceLaunchDependencies,
        resourceURL: URL? = Bundle.main.resourceURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            userGhosttyShellIntegrationMode: dependencies.userGhosttyShellIntegrationMode,
            resolvedUserShell: dependencies.resolvedUserShell,
            spawnPolicyProvider: dependencies.spawnPolicyProvider,
            runtimeFilesystem: dependencies.runtimeFilesystem,
            sessionPortBase: dependencies.sessionPortBase,
            sessionPortRangeSize: dependencies.sessionPortRangeSize,
            resourceURL: resourceURL,
            bundleIdentifier: bundleIdentifier,
            ambientEnvironment: ambientEnvironment,
            defaultShellArguments: Self.macOSLoginShellArguments,
            agentCommandShimInstallDeadline: dependencies.agentCommandShimInstallDeadline,
            agentCommandShimInstallDeadlineClock: dependencies.agentCommandShimInstallDeadlineClock
        )
    }

    public init(
        userGhosttyShellIntegrationMode: @escaping @MainActor () -> String,
        resolvedUserShell: @escaping @MainActor () -> String? = { nil },
        spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        sessionPortBase: Int,
        sessionPortRangeSize: Int,
        resourceURL: URL?,
        bundleIdentifier: String?,
        ambientEnvironment: [String: String],
        defaultShellArguments: @escaping DefaultShellArguments,
        agentCommandShimInstallDeadline: Duration = .seconds(5),
        agentCommandShimInstallDeadlineClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.userGhosttyShellIntegrationMode = userGhosttyShellIntegrationMode
        self.resolvedUserShell = resolvedUserShell
        self.spawnPolicyProvider = spawnPolicyProvider
        self.runtimeFilesystem = runtimeFilesystem
        self.sessionPortBase = sessionPortBase
        self.sessionPortRangeSize = sessionPortRangeSize
        self.resourceURL = resourceURL
        self.bundleIdentifier = bundleIdentifier
        self.ambientEnvironment = ambientEnvironment
        self.defaultShellArguments = defaultShellArguments
        self.agentCommandShimInstallDeadline = agentCommandShimInstallDeadline
        self.agentCommandShimInstallDeadlineClock = agentCommandShimInstallDeadlineClock
    }

    /// Installs per-surface agent command shims, then resolves the exact launch.
    public func resolveInstallingCommandShim(
        _ request: TerminalSurfaceLaunchRequest
    ) async -> TerminalSurfaceResolvedLaunch {
        let shims: TerminalSurfaceAgentCommandShimSet?
        if let wrapperDirectoryURL = resourceURL?.appendingPathComponent("bin", isDirectory: true) {
            let filesystem = runtimeFilesystem
            let temporaryDirectory = filesystem.agentCommandShimTemporaryDirectory
            let surfaceID = request.surfaceID
            let (results, continuation) = AsyncStream<TerminalSurfaceAgentCommandShimSet?>
                .makeStream(bufferingPolicy: .bufferingNewest(1))
            let installTask = Task.detached(priority: .utility) {
                let installed = await filesystem.installAgentCommandShims(
                    wrapperDirectoryURL,
                    surfaceID,
                    temporaryDirectory
                )
                continuation.yield(installed)
                continuation.finish()
            }
            defer {
                installTask.cancel()
                continuation.finish()
            }
            let deadline = agentCommandShimInstallDeadline
            let clock = agentCommandShimInstallDeadlineClock
            shims = await withTaskGroup(
                of: TerminalSurfaceAgentCommandShimSet?.self,
                returning: TerminalSurfaceAgentCommandShimSet?.self
            ) { group in
                group.addTask {
                    var iterator = results.makeAsyncIterator()
                    return await iterator.next() ?? nil
                }
                group.addTask {
                    do {
                        try await clock.sleep(for: deadline, tolerance: nil)
                    } catch {
                        return nil
                    }
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } else {
            shims = nil
        }
        return resolve(request, commandShims: shims)
    }

    /// Resolves spawn environment, command, working directory, and one-shot input.
    public func resolve(
        _ request: TerminalSurfaceLaunchRequest,
        commandShims: TerminalSurfaceAgentCommandShimSet?
    ) -> TerminalSurfaceResolvedLaunch {
        var baseConfig = request.configTemplate ?? CmuxSurfaceConfigTemplate()
        var environment = baseConfig.environmentVariables
        var protectedKeys: Set<String> = []
        TerminalSurface.applyManagedTerminalIdentityEnvironment(
            to: &environment,
            protectedKeys: &protectedKeys
        )

        func setManagedValue(_ key: String, _ value: String) {
            environment[key] = value
            protectedKeys.insert(key)
        }

        let resolvedShell = resolvedUserShell()?.nilIfEmpty
        if let resolvedShell {
            setManagedValue("SHELL", resolvedShell)
        }

        let socketPath = spawnPolicyProvider.controlSocketPath()
        TerminalSurface.applyManagedCmuxContextEnvironment(
            TerminalSurface.cmuxContextEnvironment(
                workspaceId: request.workspaceID,
                surfaceId: request.surfaceID,
                terminalLifecycleId: request.terminalLifecycleID,
                socketPath: socketPath
            ),
            to: &environment,
            protectedKeys: &protectedKeys
        )
        setManagedValue("CMUX_SOCKET", "")
        if let inheritedClaudeConfigDir = ambientEnvironment["CLAUDE_CONFIG_DIR"],
           !inheritedClaudeConfigDir.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(
                inheritedClaudeConfigDir
            )
        }
        if let bundledCLIURL = resourceURL?.appendingPathComponent("bin/cmux"),
           runtimeFilesystem.isExecutableFile(bundledCLIURL.path) {
            setManagedValue("CMUX_BUNDLED_CLI_PATH", bundledCLIURL.path)
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            setManagedValue("CMUX_BUNDLE_ID", bundleIdentifier)
        }

        let startPort = sessionPortBase + request.portOrdinal * sessionPortRangeSize
        setManagedValue("CMUX_PORT", String(startPort))
        setManagedValue("CMUX_PORT_END", String(startPort + sessionPortRangeSize - 1))
        setManagedValue("CMUX_PORT_RANGE", String(sessionPortRangeSize))

        let spawnPolicy = spawnPolicyProvider.currentSpawnPolicy()
        for (key, value) in spawnPolicy.socketAuthenticationEnvironment
            where !key.isEmpty && !value.isEmpty {
            setManagedValue(key, value)
        }
        if !spawnPolicy.claudeHooksEnabled {
            setManagedValue("CMUX_CLAUDE_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.codexHooksEnabled {
            setManagedValue("CMUX_CODEX_HOOKS_DISABLED", "1")
        }
        if let customClaudePath = spawnPolicy.customClaudePath {
            setManagedValue("CMUX_CUSTOM_CLAUDE_PATH", customClaudePath)
        }
        setManagedValue(
            spawnPolicy.subagentNotificationEnvironmentKey,
            spawnPolicy.suppressSubagentNotifications ? "1" : "0"
        )
        if !spawnPolicy.cursorHooksEnabled {
            setManagedValue("CMUX_CURSOR_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.geminiHooksEnabled {
            setManagedValue("CMUX_GEMINI_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.kiroHooksEnabled {
            setManagedValue("CMUX_KIRO_HOOKS_DISABLED", "1")
        }
        setManagedValue("CMUX_KIRO_NOTIFICATION_LEVEL", spawnPolicy.kiroNotificationLevel)
        if !spawnPolicy.ampHooksEnabled {
            setManagedValue("CMUX_AMP_HOOKS_DISABLED", "1")
        }

        if let cliBinURL = resourceURL?.appendingPathComponent("bin") {
            let cliBinPath = cliBinURL.path
            let ghosttyCLIPath = cliBinURL.appendingPathComponent("ghostty").path
            if runtimeFilesystem.isExecutableFile(ghosttyCLIPath) {
                setManagedValue("GHOSTTY_BIN", ghosttyCLIPath)
            }
            let currentPath = environment["PATH"] ?? ambientEnvironment["PATH"] ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                setManagedValue(
                    "PATH",
                    TerminalSurface.pathByPrependingUniqueDirectory(cliBinPath, to: currentPath)
                )
            }
        }

        if let commandShims {
            setManagedValue("CMUX_AGENT_COMMAND_SHIM_ROOT", commandShims.directoryPath)
            for shim in commandShims.shims {
                setManagedValue(shim.wrapperShimEnvironmentKey, shim.executablePath)
                setManagedValue(shim.wrapperShimRootEnvironmentKey, shim.directoryPath)
            }
            let currentPath = environment["PATH"] ?? ambientEnvironment["PATH"] ?? ""
            setManagedValue(
                "PATH",
                TerminalSurface.pathByPrependingUniqueDirectory(
                    commandShims.directoryPath,
                    to: currentPath
                )
            )
        }

        if spawnPolicy.shellIntegrationEnabled,
           let integrationDir = resourceURL?.appendingPathComponent("shell-integration").path,
           TerminalSurface.shellIntegrationDirectoryExists(integrationDir) {
            setManagedValue("CMUX_SHELL_INTEGRATION", "1")
            setManagedValue("CMUX_SHELL_INTEGRATION_DIR", integrationDir)
            TerminalSurface.applyManagedGitWatchEnvironment(
                watchGitStatusEnabled: spawnPolicy.watchGitStatusEnabled,
                showPullRequestsEnabled: spawnPolicy.showPullRequestsEnabled,
                to: &environment,
                protectedKeys: &protectedKeys
            )
            if let resolvedShell,
               let command = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
                shell: resolvedShell,
                integrationDir: integrationDir,
                userGhosttyShellIntegrationMode: userGhosttyShellIntegrationMode(),
                to: &environment,
                protectedKeys: &protectedKeys
            ), baseConfig.command?.isEmpty != false {
                baseConfig.command = command
            }
        }

        environment = TerminalSurface.mergedStartupEnvironment(
            base: environment,
            protectedKeys: protectedKeys,
            additionalEnvironment: request.additionalEnvironment,
            initialEnvironmentOverrides: request.initialEnvironmentOverrides,
            ambientEnvironment: ambientEnvironment
        )
        environment["CMUX_SOCKET"] = ""

        let workingDirectory = request.workingDirectory?.nilIfEmpty
            ?? baseConfig.workingDirectory?.nilIfEmpty
        let command = request.initialCommand?.nilIfEmpty ?? baseConfig.command?.nilIfEmpty
        let initialInput = request.runtimeInitialInput?.nilIfEmpty
            ?? request.initialInput?.nilIfEmpty
            ?? baseConfig.initialInput?.nilIfEmpty
        return TerminalSurfaceResolvedLaunch(
            workingDirectory: workingDirectory,
            command: command,
            arguments: command == nil ? defaultShellArguments() : nil,
            environment: environment,
            initialInput: initialInput,
            waitAfterCommand: baseConfig.waitAfterCommand
        )
    }

    private nonisolated static func macOSLoginShellArguments() -> [String] {
        guard let entry = getpwuid(getuid()) else {
            return ["/bin/zsh", "-l"]
        }
        let shell = String(cString: entry.pointee.pw_shell)
        let name = String(cString: entry.pointee.pw_name)
        guard !name.isEmpty else {
            return [shell, "-l"]
        }
        return [
            "/usr/bin/login", "-flp", name,
            "/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(shell)"
        ]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
