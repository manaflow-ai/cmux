public import CmuxTerminalCore
public import Foundation
internal import CMUXAgentLaunch

/// Resolves one authoritative terminal launch for either process ownership model.
@MainActor
public final class TerminalSurfaceLaunchResolver {
    /// Resolves the current user's login-shell arguments.
    public typealias DefaultShellArguments = @Sendable () -> [String]

    private let userGhosttyShellIntegrationMode: @MainActor () -> String
    private let spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding
    private let runtimeFilesystem: TerminalSurfaceRuntimeFilesystem
    private let sessionPortBase: Int
    private let sessionPortRangeSize: Int
    private let launchResourceProvider: TerminalSurfaceLaunchResourceProvider
    private let bundleIdentifier: String?
    private let ambientEnvironment: [String: String]
    private let synchronousDefaultShellArguments: [String]
    private let defaultShellArgumentsProvider: TerminalSurfaceDefaultShellArgumentsProvider
    private let resolvedUserShell: @MainActor () -> String?
    private let userGhosttyCommand: @MainActor () -> GhosttyConfiguredCommand?
    private let launchResourceSnapshotDeadline: Duration
    private let launchResourceSnapshotDeadlineClock: any Clock<Duration>
    private let agentCommandShimInstallDeadline: Duration
    private let agentCommandShimInstallDeadlineClock: any Clock<Duration>

    /// Creates a resolver from the shared launch dependencies.
    public convenience init(
        dependencies: TerminalSurfaceLaunchDependencies,
        resourceURL: URL? = Bundle.main.resourceURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            userGhosttyShellIntegrationMode: dependencies.userGhosttyShellIntegrationMode,
            resolvedUserShell: dependencies.resolvedUserShell,
            userGhosttyCommand: dependencies.userGhosttyCommand,
            spawnPolicyProvider: dependencies.spawnPolicyProvider,
            runtimeFilesystem: dependencies.runtimeFilesystem,
            sessionPortBase: dependencies.sessionPortBase,
            sessionPortRangeSize: dependencies.sessionPortRangeSize,
            resourceURL: resourceURL,
            launchResourceProvider: dependencies.launchResourceProvider,
            bundleIdentifier: bundleIdentifier,
            ambientEnvironment: ambientEnvironment,
            defaultShellArguments: ["/bin/zsh", "-l"],
            asynchronousDefaultShellArguments:
            terminalSurfaceCurrentUserLoginShellArguments,
            agentCommandShimInstallDeadline: dependencies.agentCommandShimInstallDeadline,
            agentCommandShimInstallDeadlineClock: dependencies.agentCommandShimInstallDeadlineClock
        )
    }

    /// Creates a resolver with explicit environment and timing seams.
    public init(
        userGhosttyShellIntegrationMode: @escaping @MainActor () -> String,
        resolvedUserShell: @escaping @MainActor () -> String? = { nil },
        userGhosttyCommand: @escaping @MainActor () -> GhosttyConfiguredCommand? = { nil },
        spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        sessionPortBase: Int,
        sessionPortRangeSize: Int,
        resourceURL: URL?,
        launchResourceProvider: TerminalSurfaceLaunchResourceProvider? = nil,
        bundleIdentifier: String?,
        ambientEnvironment: [String: String],
        defaultShellArguments: [String],
        asynchronousDefaultShellArguments: DefaultShellArguments? = nil,
        launchResourceSnapshotDeadline: Duration = .seconds(5),
        launchResourceSnapshotDeadlineClock: any Clock<Duration> = ContinuousClock(),
        agentCommandShimInstallDeadline: Duration = .seconds(5),
        agentCommandShimInstallDeadlineClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.userGhosttyShellIntegrationMode = userGhosttyShellIntegrationMode
        self.resolvedUserShell = resolvedUserShell
        self.userGhosttyCommand = userGhosttyCommand
        self.spawnPolicyProvider = spawnPolicyProvider
        self.runtimeFilesystem = runtimeFilesystem
        self.sessionPortBase = sessionPortBase
        self.sessionPortRangeSize = sessionPortRangeSize
        self.launchResourceProvider = launchResourceProvider
            ?? TerminalSurfaceLaunchResourceProvider(
                resourceURL: resourceURL,
                isExecutableFile: runtimeFilesystem.isExecutableFile,
                directoryExists: runtimeFilesystem.directoryExists
            )
        self.bundleIdentifier = bundleIdentifier
        self.ambientEnvironment = ambientEnvironment
        synchronousDefaultShellArguments = defaultShellArguments
        defaultShellArgumentsProvider = TerminalSurfaceDefaultShellArgumentsProvider(
            resolve: asynchronousDefaultShellArguments ?? { defaultShellArguments }
        )
        self.launchResourceSnapshotDeadline = launchResourceSnapshotDeadline
        self.launchResourceSnapshotDeadlineClock = launchResourceSnapshotDeadlineClock
        self.agentCommandShimInstallDeadline = agentCommandShimInstallDeadline
        self.agentCommandShimInstallDeadlineClock = agentCommandShimInstallDeadlineClock
    }

    /// Installs per-surface agent command shims, then resolves the exact launch.
    ///
    /// A repeated resolution can reuse the canonical terminal's existing shim
    /// lease so a placement change does not replace or remove its live directory.
    public func resolveInstallingCommandShim(
        _ request: TerminalSurfaceLaunchRequest,
        reusing commandShimLease: TerminalSurfaceAgentCommandShimLease? = nil
    ) async -> TerminalSurfaceOwnedLaunch {
        let launchResourceSnapshot = await launchResourceProvider.snapshot(
            deadline: launchResourceSnapshotDeadline,
            clock: launchResourceSnapshotDeadlineClock
        )
        let shims: TerminalSurfaceAgentCommandShimSet?
        if let commandShimLease {
            shims = commandShimLease.shims
        } else if let wrapperDirectoryURL = launchResourceSnapshot.wrapperDirectoryURL {
            let attempt = TerminalSurfaceCommandShimInstallAttempt(
                filesystem: runtimeFilesystem,
                wrapperDirectoryURL: wrapperDirectoryURL,
                surfaceID: request.surfaceID,
                deadline: agentCommandShimInstallDeadline,
                clock: agentCommandShimInstallDeadlineClock
            )
            shims = await withTaskCancellationHandler {
                await attempt.value()
            } onCancel: {
                Task { await attempt.cancel() }
            }
        } else {
            shims = nil
        }
        var resolution = resolve(
            request,
            commandShims: shims,
            launchResourceSnapshot: launchResourceSnapshot,
            defaultShellArguments: nil
        )
        var resolvedDefaultShellArguments: [String]?
        if resolution.requiresDefaultShellArguments {
            let defaultShellArguments = await defaultShellArgumentsProvider.arguments(
                fallback: synchronousDefaultShellArguments,
                deadline: agentCommandShimInstallDeadline,
                clock: agentCommandShimInstallDeadlineClock
            )
            resolvedDefaultShellArguments = defaultShellArguments
            let launchForm = TerminalSurfaceLaunchForm(arguments: defaultShellArguments)
                ?? .fallbackLoginShell
            let draft = resolution.resolvedLaunch
            resolution.resolvedLaunch = TerminalSurfaceResolvedLaunch(
                workingDirectory: draft.workingDirectory,
                launchForm: launchForm,
                environment: draft.environment,
                initialInput: draft.initialInput,
                waitAfterCommand: draft.waitAfterCommand
            )
        }
        let ownedCommandShimLease: TerminalSurfaceAgentCommandShimLease?
        if let commandShimLease {
            ownedCommandShimLease = commandShimLease
        } else if !Task.isCancelled, let shims {
            // There is no suspension between the cancellation decision and
            // lease creation. From this point, either this result owns the
            // installed directory or the cleanup owner below does.
            ownedCommandShimLease = TerminalSurfaceAgentCommandShimLease(
                shims: shims,
                removalAttemptLimit: runtimeFilesystem.agentCommandShimRemovalAttemptLimit,
                removalLane: runtimeFilesystem.agentCommandShimRemovalLane,
                remove: runtimeFilesystem.removeAgentCommandShims,
                reportRemovalFailure: runtimeFilesystem.reportAgentCommandShimRemovalFailure
            )
        } else {
            ownedCommandShimLease = nil
        }
        if commandShimLease == nil, ownedCommandShimLease == nil, let shims {
            await runtimeFilesystem.cleanupUnownedAgentCommandShims(
                shims,
                retryClock: agentCommandShimInstallDeadlineClock
            )
            resolution = resolve(
                request,
                commandShims: nil,
                launchResourceSnapshot: launchResourceSnapshot,
                defaultShellArguments: resolvedDefaultShellArguments
            )
        }
        if commandShimLease == nil, let ownedCommandShimLease {
            let cleanupFilesystem = runtimeFilesystem
            let cleanupClock = agentCommandShimInstallDeadlineClock
            return TerminalSurfaceOwnedLaunch(
                resolvedLaunch: resolution.resolvedLaunch,
                provisionalCommandShimLease: ownedCommandShimLease,
                cleanupUnacceptedLease: { lease in
                    await cleanupFilesystem.cleanupUnownedAgentCommandShims(
                        lease.shims,
                        retryClock: cleanupClock
                    )
                }
            )
        }
        return TerminalSurfaceOwnedLaunch(
            resolvedLaunch: resolution.resolvedLaunch,
            borrowingCommandShimLease: ownedCommandShimLease
        )
    }

    /// Resolves spawn environment, command, working directory, and one-shot input.
    public func resolve(
        _ request: TerminalSurfaceLaunchRequest,
        commandShims: TerminalSurfaceAgentCommandShimSet?,
        launchResourceSnapshot: TerminalSurfaceLaunchResourceSnapshot
    ) -> TerminalSurfaceResolvedLaunch {
        resolve(
            request,
            commandShims: commandShims,
            launchResourceSnapshot: launchResourceSnapshot,
            defaultShellArguments: synchronousDefaultShellArguments
        ).resolvedLaunch
    }

    private func resolve(
        _ request: TerminalSurfaceLaunchRequest,
        commandShims: TerminalSurfaceAgentCommandShimSet?,
        launchResourceSnapshot: TerminalSurfaceLaunchResourceSnapshot,
        defaultShellArguments: [String]?
    ) -> (
        resolvedLaunch: TerminalSurfaceResolvedLaunch,
        requiresDefaultShellArguments: Bool
    ) {
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

        func omitManagedValue(_ key: String) {
            environment.removeValue(forKey: key)
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
           !inheritedClaudeConfigDir.isEmpty
        {
            environment["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(
                inheritedClaudeConfigDir
            )
        }
        if let bundledCLIPath = launchResourceSnapshot.bundledCLIPath {
            setManagedValue("CMUX_BUNDLED_CLI_PATH", bundledCLIPath)
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            setManagedValue("CMUX_BUNDLE_ID", bundleIdentifier)
        }

        if let portRange = Self.sessionPortRange(
            base: sessionPortBase,
            ordinal: request.portOrdinal,
            size: sessionPortRangeSize
        ) {
            setManagedValue("CMUX_PORT", String(portRange.lowerBound))
            setManagedValue("CMUX_PORT_END", String(portRange.upperBound))
            setManagedValue("CMUX_PORT_RANGE", String(sessionPortRangeSize))
        } else {
            omitManagedValue("CMUX_PORT")
            omitManagedValue("CMUX_PORT_END")
            omitManagedValue("CMUX_PORT_RANGE")
        }

        let spawnPolicy = spawnPolicyProvider.currentSpawnPolicy()
        for (key, value) in spawnPolicy.socketAuthenticationEnvironment
            where !key.isEmpty && !value.isEmpty
        {
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

        if let cliBinPath = launchResourceSnapshot.cliBinPath {
            if let ghosttyCLIPath = launchResourceSnapshot.ghosttyCLIPath {
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

        let surfaceConfiguredCommand = baseConfig.command.flatMap(
            GhosttyConfiguredCommand.init(rawValue:)
        )
        var managedShellCommand: String?
        if spawnPolicy.shellIntegrationEnabled,
           let integrationDir = launchResourceSnapshot.shellIntegrationDirectoryPath
        {
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
               ), surfaceConfiguredCommand == nil
            {
                managedShellCommand = command
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
        let configuredLaunchForm = TerminalLaunchCommandPolicy().resolve(
            initialCommand: request.initialCommand?.nilIfEmpty,
            surfaceCommand: surfaceConfiguredCommand,
            userGhosttyCommand: userGhosttyCommand(),
            managedShellCommand: managedShellCommand,
            resolvedShell: resolvedShell
        )
        let runtimeInitialInput = request.runtimeInitialInput?.nilIfEmpty
        let appInitialInput = request.initialInput?.nilIfEmpty
            ?? baseConfig.initialInput?.nilIfEmpty
        let initialInput = runtimeInitialInput.map {
            $0 + (appInitialInput ?? "")
        } ?? appInitialInput
        let requiresDefaultShellArguments = configuredLaunchForm == nil
        let launchForm = configuredLaunchForm
            ?? defaultShellArguments.flatMap(TerminalSurfaceLaunchForm.init(arguments:))
            ?? .fallbackLoginShell
        return (
            resolvedLaunch: TerminalSurfaceResolvedLaunch(
                workingDirectory: workingDirectory,
                launchForm: launchForm,
                environment: environment,
                initialInput: initialInput,
                waitAfterCommand: baseConfig.waitAfterCommand
            ),
            requiresDefaultShellArguments: requiresDefaultShellArguments
        )
    }

    private static func sessionPortRange(
        base: Int,
        ordinal: Int,
        size: Int
    ) -> ClosedRange<Int>? {
        guard base >= 1, ordinal >= 0, size > 0 else { return nil }
        let (offset, offsetOverflowed) = ordinal.multipliedReportingOverflow(by: size)
        guard !offsetOverflowed else { return nil }
        let (start, startOverflowed) = base.addingReportingOverflow(offset)
        guard !startOverflowed else { return nil }
        let (end, endOverflowed) = start.addingReportingOverflow(size - 1)
        guard !endOverflowed, start >= 1, end <= 65_535 else { return nil }
        return start ... end
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
