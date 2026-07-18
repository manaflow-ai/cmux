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
        let baseConfig = configTemplate ?? CmuxSurfaceConfigTemplate()
        let runtimeInitialInput = nextRuntimeInitialInput
        let resolvedLaunch = TerminalSurfaceLaunchResolver(
            userGhosttyShellIntegrationMode: { [engine] in
                engine.userGhosttyShellIntegrationMode
            },
            spawnPolicyProvider: spawnPolicyProvider,
            runtimeFilesystem: runtimeFilesystem,
            sessionPortBase: sessionPortBase,
            sessionPortRangeSize: sessionPortRangeSize,
            resourceURL: Bundle.main.resourceURL,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            ambientEnvironment: ProcessInfo.processInfo.environment,
            // Embedded Ghostty computes its own default-shell argv. The shared
            // resolver still requires a valid mutually-exclusive launch form.
            defaultShellArguments: { ["/bin/zsh", "-l"] }
        ).resolve(
            TerminalSurfaceLaunchRequest(
                workspaceID: tabId,
                surfaceID: id,
                configTemplate: configTemplate,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                initialCommand: initialCommand,
                initialInput: initialInput,
                runtimeInitialInput: runtimeInitialInput,
                initialEnvironmentOverrides: initialEnvironmentOverrides,
                additionalEnvironment: additionalEnvironment
            ),
            commandShim: claudeShim
        )
        var surfaceConfig = ghostty_surface_config_new()
        let magnificationPercent = globalFontMagnificationPercent()
        surfaceConfig.font_size = CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: baseConfig.fontSize,
            percent: magnificationPercent
        )
        surfaceConfig.wait_after_command = resolvedLaunch.waitAfterCommand
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

        if !resolvedLaunch.environment.isEmpty {
            envVars.reserveCapacity(resolvedLaunch.environment.count)
            envStorage.reserveCapacity(resolvedLaunch.environment.count)
            for (key, value) in resolvedLaunch.environment {
                guard let keyPtr = strdup(key) else { continue }
                guard let valuePtr = strdup(value) else {
                    free(keyPtr)
                    continue
                }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createdSurface = withOptionalCString(resolvedLaunch.command) { cCommand in
            surfaceConfig.command = cCommand
            return withOptionalCString(resolvedLaunch.workingDirectory) { cWorkingDir in
                surfaceConfig.working_directory = cWorkingDir
                return withOptionalCString(resolvedLaunch.initialInput) { cInitialInput in
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
