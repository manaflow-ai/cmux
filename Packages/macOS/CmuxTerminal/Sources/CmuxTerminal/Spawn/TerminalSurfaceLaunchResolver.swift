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
    private let launchResourceProvider: TerminalSurfaceLaunchResourceProvider
    private let bundleIdentifier: String?
    private let ambientEnvironment: [String: String]
    private let defaultShellArguments: DefaultShellArguments
    private let resolvedUserShell: @MainActor () -> String?
    private let userGhosttyCommand: @MainActor () -> GhosttyConfiguredCommand?
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
            userGhosttyCommand: dependencies.userGhosttyCommand,
            spawnPolicyProvider: dependencies.spawnPolicyProvider,
            runtimeFilesystem: dependencies.runtimeFilesystem,
            sessionPortBase: dependencies.sessionPortBase,
            sessionPortRangeSize: dependencies.sessionPortRangeSize,
            resourceURL: resourceURL,
            launchResourceProvider: dependencies.launchResourceProvider,
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
        userGhosttyCommand: @escaping @MainActor () -> GhosttyConfiguredCommand? = { nil },
        spawnPolicyProvider: any TerminalSurfaceSpawnPolicyProviding,
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem,
        sessionPortBase: Int,
        sessionPortRangeSize: Int,
        resourceURL: URL?,
        launchResourceProvider: TerminalSurfaceLaunchResourceProvider? = nil,
        bundleIdentifier: String?,
        ambientEnvironment: [String: String],
        defaultShellArguments: @escaping DefaultShellArguments,
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
                fileManager: .default
            )
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
        let launchResourceSnapshot = await launchResourceProvider.snapshot()
        let shims: TerminalSurfaceAgentCommandShimSet?
        if let wrapperDirectoryURL = launchResourceSnapshot.wrapperDirectoryURL {
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
                attempt.cancel()
            }
        } else {
            shims = nil
        }
        return resolve(
            request,
            commandShims: shims,
            launchResourceSnapshot: launchResourceSnapshot
        )
    }

    /// Resolves spawn environment, command, working directory, and one-shot input.
    public func resolve(
        _ request: TerminalSurfaceLaunchRequest,
        commandShims: TerminalSurfaceAgentCommandShimSet?,
        launchResourceSnapshot: TerminalSurfaceLaunchResourceSnapshot
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
        if let bundledCLIPath = launchResourceSnapshot.bundledCLIPath {
            setManagedValue("CMUX_BUNDLED_CLI_PATH", bundledCLIPath)
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

        var managedShellCommand: String?
        if spawnPolicy.shellIntegrationEnabled,
           let integrationDir = launchResourceSnapshot.shellIntegrationDirectoryPath {
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
            surfaceCommand: baseConfig.command?.nilIfEmpty,
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
        let launchForm = configuredLaunchForm
            ?? TerminalSurfaceLaunchForm(arguments: defaultShellArguments())
            ?? .fallbackLoginShell
        return TerminalSurfaceResolvedLaunch(
            workingDirectory: workingDirectory,
            launchForm: launchForm,
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

/// Owns a best-effort shim install without making terminal launch wait for a
/// filesystem operation to acknowledge cancellation. The installer is asked
/// to stop at the injected deadline, but this owner can publish `nil` first and
/// release launch even when an OS filesystem call returns late.
private final class TerminalSurfaceCommandShimInstallAttempt: @unchecked Sendable {
    private enum State {
        case pending
        case resolved(TerminalSurfaceAgentCommandShimSet?)
    }

    private let lock = NSLock()
    private var state = State.pending
    private var continuation:
        CheckedContinuation<TerminalSurfaceAgentCommandShimSet?, Never>?
    private var installTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private let installLease: TerminalSurfaceCommandShimInstallLease

    init(
        filesystem: TerminalSurfaceRuntimeFilesystem,
        wrapperDirectoryURL: URL,
        surfaceID: UUID,
        deadline: Duration,
        clock: any Clock<Duration>
    ) {
        let installLease = TerminalSurfaceCommandShimInstallLease(
            gate: filesystem.agentCommandShimInstallGate
        )
        self.installLease = installLease
        let temporaryDirectory = filesystem.agentCommandShimTemporaryDirectory
        let installTask = Task.detached(priority: .utility) { [weak self, installLease] in
            guard let installToken = await installLease.acquire() else {
                self?.resolve(nil)
                return
            }
            defer {
                installLease.release(installToken)
            }
            guard !Task.isCancelled else { return }
            let shims = await filesystem.installAgentCommandShims(
                wrapperDirectoryURL,
                surfaceID,
                temporaryDirectory
            )
            guard self?.resolve(shims) == true else {
                if let shims {
                    await filesystem.removeAgentCommandShims(shims)
                }
                return
            }
        }
        let deadlineTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await clock.sleep(for: deadline, tolerance: nil)
            } catch {
                return
            }
            self?.resolve(nil, invalidatingInstall: true)
        }
        attach(installTask: installTask, deadlineTask: deadlineTask)
    }

    func value() async -> TerminalSurfaceAgentCommandShimSet? {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case .pending:
                precondition(self.continuation == nil)
                self.continuation = continuation
                lock.unlock()
            case .resolved(let shims):
                lock.unlock()
                continuation.resume(returning: shims)
            }
        }
    }

    func cancel() {
        resolve(nil, invalidatingInstall: true)
    }

    private func attach(
        installTask: Task<Void, Never>,
        deadlineTask: Task<Void, Never>
    ) {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            installTask.cancel()
            deadlineTask.cancel()
            return
        }
        self.installTask = installTask
        self.deadlineTask = deadlineTask
        lock.unlock()
    }

    @discardableResult
    private func resolve(
        _ shims: TerminalSurfaceAgentCommandShimSet?,
        invalidatingInstall: Bool = false
    ) -> Bool {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            return false
        }
        state = .resolved(shims)
        let continuation = continuation
        self.continuation = nil
        let installTask = installTask
        self.installTask = nil
        let deadlineTask = deadlineTask
        self.deadlineTask = nil
        lock.unlock()

        if invalidatingInstall {
            installLease.invalidate()
        }
        installTask?.cancel()
        deadlineTask?.cancel()
        continuation?.resume(returning: shims)
        return true
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
