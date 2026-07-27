internal import AppKit
internal import Foundation
internal import GhosttyKit
internal import CmuxTerminalCore
internal import CMUXAgentLaunch
internal import Darwin
#if DEBUG
internal import CMUXDebugLog
#endif

// MARK: - Native runtime-surface creation/config assembly

struct ResolvedTerminalRuntimeLaunchConfiguration {
    let templateFontSize: Float32
    let fontSize: Float32
    let waitAfterCommand: Bool
    let environment: [String: String]
    let workingDirectory: String?
    let command: String?
    let initialInput: String?
    let runtimeInitialInput: String?
}

extension TerminalSurface {
    @MainActor
    func createNativeRuntimeSurface(
        app: ghostty_app_t,
        for view: any TerminalSurfaceNativeViewing,
        scaleFactors: (x: CGFloat, y: CGFloat, layer: CGFloat),
        claudeShim: ClaudeCommandShim?
    ) -> (createdSurface: ghostty_surface_t?, runtimeInitialInput: String?) {
        let launchConfiguration = resolvedRuntimeLaunchConfiguration(claudeShim: claudeShim)
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.font_size = launchConfiguration.fontSize
        surfaceConfig.wait_after_command = launchConfiguration.waitAfterCommand
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view as NSView).toOpaque()
        ))
        let rendererRealization = rendererRealization
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(
            surfaceHost: view,
            surfaceController: self,
            rendererMailboxDidDrain: { surfaceID in
                Task { @MainActor in
                    rendererRealization.scheduleRendererPresentationRepair(surfaceID: surfaceID)
                }
            }
        ))
        surfaceConfig.userdata = callbackContext.toOpaque()
        surfaceConfig.renderer_event_cb = terminalRendererEventCallback
        surfaceCallbackContext?.release()
        surfaceCallbackContext = callbackContext
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
        if manualIO {
            // MANUAL I/O: ghostty spawns no process; typed input is delivered
            // to our callback and output is injected through
            // ghostty_surface_process_output.
            manualIOContext?.release()
            let box = Unmanaged.passRetained(
                TerminalManualIOWriteBox(onWrite: manualInputHandler ?? { _ in })
            )
            manualIOContext = box
            surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
            surfaceConfig.io_write_cb = terminalManualIOWriteCallback
            surfaceConfig.io_write_userdata = box.toOpaque()
        }
#if DEBUG
        let templateFontText = String(format: "%.2f", launchConfiguration.templateFontSize)
        let runtimeFontText = String(format: "%.2f", surfaceConfig.font_size)
        logDebugEvent(
            "zoom.create surface=\(id.uuidString.prefix(5)) context=\(GhosttySurfaceRuntimeProbe.contextName(surfaceContext)) " +
            "templateFont=\(templateFontText) runtimeFont=\(runtimeFontText)"
        )
#endif
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        if !launchConfiguration.environment.isEmpty {
            envVars.reserveCapacity(launchConfiguration.environment.count)
            envStorage.reserveCapacity(launchConfiguration.environment.count)
            for (key, value) in launchConfiguration.environment {
                guard let keyPtr = strdup(key) else { continue }
                guard let valuePtr = strdup(value) else {
                    free(keyPtr)
                    continue
                }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createdSurface = withOptionalCString(launchConfiguration.command) { cCommand in
            surfaceConfig.command = cCommand
            return withOptionalCString(launchConfiguration.workingDirectory) { cWorkingDir in
                surfaceConfig.working_directory = cWorkingDir
                return withOptionalCString(launchConfiguration.initialInput) { cInitialInput in
                    surfaceConfig.initial_input = cInitialInput
                    return makeGhosttySurface(app: app, config: &surfaceConfig, envVars: &envVars)
                }
            }
        }

        return (createdSurface, launchConfiguration.runtimeInitialInput)
    }

    @MainActor
    func resolvedRuntimeLaunchConfiguration(
        claudeShim: ClaudeCommandShim?
    ) -> ResolvedTerminalRuntimeLaunchConfiguration {
        let baseConfig = runtimeCreationConfigTemplate()
        let magnificationPercent = globalFontMagnificationPercent()
        let fontSize = CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: baseConfig.fontSize,
            percent: magnificationPercent
        )
        var environment = baseConfig.environmentVariables
        var protectedStartupEnvironmentKeys: Set<String> = []
        Self.applyManagedTerminalIdentityEnvironment(
            to: &environment,
            protectedKeys: &protectedStartupEnvironmentKeys
        )

        func setManagedEnvironmentValue(_ key: String, _ value: String) {
            environment[key] = value
            protectedStartupEnvironmentKeys.insert(key)
        }

        if let resolvedUserShell = engine.resolvedUserShell {
            setManagedEnvironmentValue("SHELL", resolvedUserShell)
        }

        let socketPath = spawnPolicyProvider.controlSocketPath()
        Self.applyManagedCmuxContextEnvironment(
            Self.cmuxContextEnvironment(
                workspaceId: tabId,
                surfaceId: id,
                socketPath: socketPath
            ),
            to: &environment,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        setManagedEnvironmentValue("CMUX_SOCKET", "")
        if let inheritedClaudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !inheritedClaudeConfigDir.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(
                inheritedClaudeConfigDir
            )
        }
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
           runtimeFilesystem.isExecutableFile(bundledCLIURL.path) {
            setManagedEnvironmentValue("CMUX_BUNDLED_CLI_PATH", bundledCLIURL.path)
        }
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            setManagedEnvironmentValue("CMUX_BUNDLE_ID", bundleId)
        }

        let startPort = sessionPortBase + portOrdinal * sessionPortRangeSize
        setManagedEnvironmentValue("CMUX_PORT", String(startPort))
        setManagedEnvironmentValue(
            "CMUX_PORT_END",
            String(startPort + sessionPortRangeSize - 1)
        )
        setManagedEnvironmentValue("CMUX_PORT_RANGE", String(sessionPortRangeSize))

        let spawnPolicy = spawnPolicyProvider.currentSpawnPolicy()
        for (key, value) in spawnPolicy.socketAuthenticationEnvironment
            where !key.isEmpty && !value.isEmpty {
            setManagedEnvironmentValue(key, value)
        }
        if !spawnPolicy.claudeHooksEnabled {
            setManagedEnvironmentValue("CMUX_CLAUDE_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.codexHooksEnabled {
            setManagedEnvironmentValue("CMUX_CODEX_HOOKS_DISABLED", "1")
        }
        if let customClaudePath = spawnPolicy.customClaudePath {
            setManagedEnvironmentValue("CMUX_CUSTOM_CLAUDE_PATH", customClaudePath)
        }
        setManagedEnvironmentValue(
            spawnPolicy.subagentNotificationEnvironmentKey,
            spawnPolicy.suppressSubagentNotifications ? "1" : "0"
        )
        if !spawnPolicy.cursorHooksEnabled {
            setManagedEnvironmentValue("CMUX_CURSOR_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.geminiHooksEnabled {
            setManagedEnvironmentValue("CMUX_GEMINI_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.kiroHooksEnabled {
            setManagedEnvironmentValue("CMUX_KIRO_HOOKS_DISABLED", "1")
        }
        setManagedEnvironmentValue(
            "CMUX_KIRO_NOTIFICATION_LEVEL",
            spawnPolicy.kiroNotificationLevel
        )
        if !spawnPolicy.ampHooksEnabled {
            setManagedEnvironmentValue("CMUX_AMP_HOOKS_DISABLED", "1")
        }

        if let cliBinURL = Bundle.main.resourceURL?.appendingPathComponent("bin") {
            let cliBinPath = cliBinURL.path
            let ghosttyCLIPath = cliBinURL.appendingPathComponent("ghostty").path
            if FileManager.default.isExecutableFile(atPath: ghosttyCLIPath) {
                setManagedEnvironmentValue("GHOSTTY_BIN", ghosttyCLIPath)
            }
            let currentPath = environment["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                setManagedEnvironmentValue(
                    "PATH",
                    Self.pathByPrependingUniqueDirectory(cliBinPath, to: currentPath)
                )
            }
        }

        if let claudeShim {
            setManagedEnvironmentValue(
                "CMUX_CLAUDE_WRAPPER_SHIM",
                claudeShim.executablePath
            )
            setManagedEnvironmentValue(
                "CMUX_CLAUDE_WRAPPER_SHIM_ROOT",
                claudeShim.directoryPath
            )
            if let codexShim = claudeShim.codexCommandShim {
                setManagedEnvironmentValue(
                    "CMUX_CODEX_WRAPPER_SHIM",
                    codexShim.executablePath
                )
                setManagedEnvironmentValue(
                    "CMUX_CODEX_WRAPPER_SHIM_ROOT",
                    codexShim.directoryPath
                )
            }
            let currentPath = environment["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            setManagedEnvironmentValue(
                "PATH",
                Self.pathByPrependingUniqueDirectory(claudeShim.directoryPath, to: currentPath)
            )
        }

        var managedShellCommand: String?
        if spawnPolicy.shellIntegrationEnabled,
           let integrationDirectory = Bundle.main.resourceURL?
               .appendingPathComponent("shell-integration").path,
           Self.shellIntegrationDirectoryExists(integrationDirectory) {
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION", "1")
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION_DIR", integrationDirectory)
            Self.applyManagedGitWatchEnvironment(
                watchGitStatusEnabled: spawnPolicy.watchGitStatusEnabled,
                showPullRequestsEnabled: spawnPolicy.showPullRequestsEnabled,
                to: &environment,
                protectedKeys: &protectedStartupEnvironmentKeys
            )

            if let shell = engine.resolvedUserShell {
                managedShellCommand = Self.applyManagedShellSpecificStartupEnvironment(
                    shell: shell,
                    integrationDir: integrationDirectory,
                    userGhosttyShellIntegrationMode: engine.userGhosttyShellIntegrationMode,
                    to: &environment,
                    protectedKeys: &protectedStartupEnvironmentKeys
                )
            }
        }
        environment = Self.mergedStartupEnvironment(
            base: environment,
            protectedKeys: protectedStartupEnvironmentKeys,
            additionalEnvironment: additionalEnvironment,
            initialEnvironmentOverrides: initialEnvironmentOverrides
        )
        environment["CMUX_SOCKET"] = ""

        let resolvedWorkingDirectory: String? = {
            if let workingDirectory, !workingDirectory.isEmpty {
                return workingDirectory
            }
            return baseConfig.workingDirectory
        }()
        let resolvedCommand = TerminalLaunchCommandPolicy().resolve(
            initialCommand: initialCommand,
            surfaceCommand: baseConfig.command,
            hasUserGhosttyCommand: engine.hasUserGhosttyCommand,
            managedShellCommand: managedShellCommand,
            resolvedShell: engine.resolvedUserShell
        )
        let runtimeInitialInput = nextRuntimeInitialInput
        let resolvedInitialInput: String? = {
            if let runtimeInitialInput, !runtimeInitialInput.isEmpty {
                return runtimeInitialInput
            }
            if let initialInput, !initialInput.isEmpty {
                return initialInput
            }
            return baseConfig.initialInput
        }()

        return ResolvedTerminalRuntimeLaunchConfiguration(
            templateFontSize: baseConfig.fontSize,
            fontSize: fontSize,
            waitAfterCommand: baseConfig.waitAfterCommand,
            environment: environment,
            workingDirectory: resolvedWorkingDirectory,
            command: resolvedCommand,
            initialInput: resolvedInitialInput,
            runtimeInitialInput: runtimeInitialInput
        )
    }

    private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value else {
            return body(nil)
        }
        return value.withCString(body)
    }

    private func makeGhosttySurface(
        app: ghostty_app_t,
        config surfaceConfig: inout ghostty_surface_config_s,
        envVars: inout [ghostty_env_var_s]
    ) -> ghostty_surface_t? {
        if envVars.isEmpty {
            return ghostty_surface_new(app, &surfaceConfig)
        }

        let envVarsCount = envVars.count
        return envVars.withUnsafeMutableBufferPointer { buffer in
            surfaceConfig.env_vars = buffer.baseAddress
            surfaceConfig.env_var_count = envVarsCount
            return ghostty_surface_new(app, &surfaceConfig)
        }
    }
}
