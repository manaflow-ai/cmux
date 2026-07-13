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

extension TerminalSurface {
    @MainActor
    func createNativeRuntimeSurface(
        app: ghostty_app_t,
        for view: any TerminalSurfaceNativeViewing,
        scaleFactors: (x: CGFloat, y: CGFloat, layer: CGFloat),
        claudeShim: ClaudeCommandShim?
    ) -> (createdSurface: ghostty_surface_t?, runtimeInitialInput: String?) {
        var baseConfig = configTemplate ?? CmuxSurfaceConfigTemplate()
        var surfaceConfig = ghostty_surface_config_new()
        let magnificationPercent = globalFontMagnificationPercent()
        surfaceConfig.font_size = CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: baseConfig.fontSize,
            percent: magnificationPercent
        )
        surfaceConfig.wait_after_command = baseConfig.waitAfterCommand
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view as NSView).toOpaque()
        ))
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(surfaceHost: view, surfaceController: self))
        surfaceConfig.userdata = callbackContext.toOpaque()
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
        let templateFontText = String(format: "%.2f", baseConfig.fontSize)
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

        var env = baseConfig.environmentVariables

        var protectedStartupEnvironmentKeys: Set<String> = []
        Self.applyManagedTerminalIdentityEnvironment(
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        func setManagedEnvironmentValue(_ key: String, _ value: String) {
            env[key] = value
            protectedStartupEnvironmentKeys.insert(key)
        }

        let socketPath = spawnPolicyProvider.controlSocketPath()
        Self.applyManagedCmuxContextEnvironment(
            Self.cmuxContextEnvironment(
                workspaceId: tabId,
                surfaceId: id,
                socketPath: socketPath
            ),
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        setManagedEnvironmentValue("CMUX_SOCKET", "")
        if let inheritedClaudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !inheritedClaudeConfigDir.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(inheritedClaudeConfigDir)
        }
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
           runtimeFilesystem.isExecutableFile(bundledCLIURL.path) {
            setManagedEnvironmentValue("CMUX_BUNDLED_CLI_PATH", bundledCLIURL.path)
        }
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            setManagedEnvironmentValue("CMUX_BUNDLE_ID", bundleId)
        }

        // Port range for this workspace is snapshotted once per app session.
        do {
            let startPort = sessionPortBase + portOrdinal * sessionPortRangeSize
            setManagedEnvironmentValue("CMUX_PORT", String(startPort))
            setManagedEnvironmentValue("CMUX_PORT_END", String(startPort + sessionPortRangeSize - 1))
            setManagedEnvironmentValue("CMUX_PORT_RANGE", String(sessionPortRangeSize))
        }

        let spawnPolicy = spawnPolicyProvider.currentSpawnPolicy()
        for (key, value) in spawnPolicy.socketAuthenticationEnvironment
            where !key.isEmpty && !value.isEmpty {
            setManagedEnvironmentValue(key, value)
        }
        let claudeHooksEnabled = spawnPolicy.claudeHooksEnabled
        if !claudeHooksEnabled {
            setManagedEnvironmentValue("CMUX_CLAUDE_HOOKS_DISABLED", "1")
        }
        // The codex wrapper shim is still installed (it stays on PATH so a
        // resumed codex routes through it), but when the Codex integration is
        // off the wrapper no-ops on this env var and injects no hooks, mirroring
        // the Claude toggle.
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
        setManagedEnvironmentValue("CMUX_KIRO_NOTIFICATION_LEVEL", spawnPolicy.kiroNotificationLevel)
        if !spawnPolicy.ampHooksEnabled {
            setManagedEnvironmentValue("CMUX_AMP_HOOKS_DISABLED", "1")
        }

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
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
            setManagedEnvironmentValue("CMUX_CLAUDE_WRAPPER_SHIM", claudeShim.executablePath)
            setManagedEnvironmentValue("CMUX_CLAUDE_WRAPPER_SHIM_ROOT", claudeShim.directoryPath)
            // Carry the sibling codex wrapper-shim path into the managed env too,
            // mirroring the claude shim. The auto-resume command for a codex
            // session resolves the codex executable through CMUX_CODEX_WRAPPER_SHIM
            // (see AgentResumeArgv.codexWrapperShellExecutableToken), so without
            // this the resumed codex bypasses cmux-codex-wrapper and loses its
            // hooks (iOS GUI stays read-only). The shim lives in the same
            // per-surface directory already prepended to PATH below.
            if let codexShim = claudeShim.codexCommandShim {
                setManagedEnvironmentValue("CMUX_CODEX_WRAPPER_SHIM", codexShim.executablePath)
                setManagedEnvironmentValue("CMUX_CODEX_WRAPPER_SHIM_ROOT", codexShim.directoryPath)
            }
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            setManagedEnvironmentValue(
                "PATH",
                Self.pathByPrependingUniqueDirectory(claudeShim.directoryPath, to: currentPath)
            )
        }

        if spawnPolicy.shellIntegrationEnabled,
           let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path,
           Self.shellIntegrationDirectoryExists(integrationDir) {
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION", "1")
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION_DIR", integrationDir)
            Self.applyManagedGitWatchEnvironment(
                watchGitStatusEnabled: spawnPolicy.watchGitStatusEnabled,
                showPullRequestsEnabled: spawnPolicy.showPullRequestsEnabled,
                to: &env,
                protectedKeys: &protectedStartupEnvironmentKeys
            )

            let shell = (env["SHELL"]?.isEmpty == false ? env["SHELL"] : nil)
                ?? getenv("SHELL").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            if let command = Self.applyManagedShellSpecificStartupEnvironment(
                shell: shell,
                integrationDir: integrationDir,
                userGhosttyShellIntegrationMode: engine.userGhosttyShellIntegrationMode,
                to: &env,
                protectedKeys: &protectedStartupEnvironmentKeys
            ) {
                if baseConfig.command?.isEmpty != false { baseConfig.command = command }
            }
        }
        env = Self.mergedStartupEnvironment(
            base: env,
            protectedKeys: protectedStartupEnvironmentKeys,
            additionalEnvironment: additionalEnvironment,
            initialEnvironmentOverrides: initialEnvironmentOverrides
        )
        env["CMUX_SOCKET"] = ""

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key) else { continue }
                guard let valuePtr = strdup(value) else {
                    free(keyPtr)
                    continue
                }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let resolvedWorkingDirectory: String? = {
            if let workingDirectory, !workingDirectory.isEmpty {
                return workingDirectory
            }
            return baseConfig.workingDirectory
        }()
        let resolvedCommand: String? = {
            if let initialCommand, !initialCommand.isEmpty {
                return initialCommand
            }
            return baseConfig.command
        }()
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

        let createdSurface = withOptionalCString(resolvedCommand) { cCommand in
            surfaceConfig.command = cCommand
            return withOptionalCString(resolvedWorkingDirectory) { cWorkingDir in
                surfaceConfig.working_directory = cWorkingDir
                return withOptionalCString(resolvedInitialInput) { cInitialInput in
                    surfaceConfig.initial_input = cInitialInput
                    return makeGhosttySurface(app: app, config: &surfaceConfig, envVars: &envVars)
                }
            }
        }

        return (createdSurface, runtimeInitialInput)
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
