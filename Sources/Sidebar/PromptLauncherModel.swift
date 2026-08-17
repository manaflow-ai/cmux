import Foundation
import Observation
import CmuxSettings

@MainActor
@Observable final class PromptLauncherModel {
    var promptText: String = ""
    var selectedTarget: String = ""
    var selectedProvider: String = ""
    var selectedRepository: String = ""
    var isLoading: Bool = false

    private struct RunResult {
        let succeeded: Bool
        let message: String?
    }

    func configure(_ config: CmuxPromptLauncherDefinition) {
        if !config.repositories.isEmpty,
           !config.repositories.contains(where: { $0.id == selectedRepository }) {
            selectedRepository = config.selectedDefaultRepositoryID
            selectedTarget = config.selectedDefaultTargetID(forRepositoryID: selectedRepository)
        }
        let availableTargets = config.targets(forRepositoryID: selectedRepository)
        if !availableTargets.contains(where: { $0.id == selectedTarget }) {
            selectedTarget = config.repositories.isEmpty
                ? config.selectedDefaultTargetID
                : config.selectedDefaultTargetID(forRepositoryID: selectedRepository)
        }
        if !config.providers.contains(where: { $0.id == selectedProvider }) {
            selectedProvider = config.selectedDefaultProviderID
        }
    }

    func selectRepository(_ repositoryID: String, config: CmuxPromptLauncherDefinition) {
        selectedRepository = repositoryID
        selectedTarget = config.selectedDefaultTargetID(forRepositoryID: repositoryID)
    }

    func launch(
        config: CmuxPromptLauncherDefinition,
        tabManager: TabManager,
        configSourcePath: String?,
        globalConfigPath: String
    ) {
        configure(config)
        let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isLoading else { return }
        guard let shellCmd = SidebarPromptLauncherTemplateRenderer.renderCommand(
            config: config,
            targetID: selectedTarget,
            providerID: selectedProvider,
            repositoryID: config.repositories.isEmpty ? nil : selectedRepository,
            prompt: prompt
        ) else {
            return
        }

        CmuxConfigExecutor.authorizePromptLauncherIfNeeded(
            promptLauncher: config,
            renderedCommand: shellCmd,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath
        ) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            self.startLaunch(
                shellCmd: shellCmd,
                config: config,
                prompt: prompt,
                tabManager: tabManager
            )
        }
    }

    private func startLaunch(
        shellCmd: String,
        config: CmuxPromptLauncherDefinition,
        prompt _: String,
        tabManager: TabManager
    ) {
        isLoading = true
        promptText = ""
        Task { @MainActor in
            let result = await runPromptCommand(shellCmd: shellCmd, config: config, tabManager: tabManager)
            isLoading = false
            if result.succeeded {
                promptText = ""
            } else {
                let message = result.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                promptText = (message?.isEmpty == false) ? message! : String(localized: "sidebar.prompt_launcher.failed",
                                                                              defaultValue: "Prompt launcher failed")
            }
        }
    }

    private func setLastLogLine(_ line: String) {
        promptText = line
    }

    private func runPromptCommand(
        shellCmd: String,
        config: CmuxPromptLauncherDefinition,
        tabManager: TabManager
    ) async -> RunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", shellCmd]

        var env = ProcessInfo.processInfo.environment
        for (key, value) in config.environment {
            env[key] = value
        }
        if config.forwardCmuxSocket {
            env["CMUX_SOCKET_PATH"] = SocketControlSettings.socketPath()
        }
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice

        return await withCheckedContinuation { [weak self] (cont: CheckedContinuation<RunResult, Never>) in
            // Thread-safe single-fire unlock: resume the continuation exactly once,
            // either when the workspace appears in cmux or when the process exits.
            let lock = NSLock()
            var resumed = false
            var latestLine = ""
            let updateLatestLine: (String) -> Void = { line in
                lock.lock(); defer { lock.unlock() }
                latestLine = line
            }
            let currentLatestLine: () -> String = {
                lock.lock(); defer { lock.unlock() }
                return latestLine
            }
            let resume: (RunResult) -> Void = { result in
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: result)
            }

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let str = String(data: data, encoding: .utf8) else { return }
                let newLines = SidebarPromptLauncherTemplateRenderer.stripAnsi(str)
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard let last = newLines.last else { return }
                updateLatestLine(last)
                Task { @MainActor [weak self, weak tabManager] in
                    self?.setLastLogLine(last)
                    guard let tabManager else { return }
                    for line in newLines {
                        if let metadata = SidebarPromptLauncherTemplateRenderer.metadata(
                            from: line,
                            prefix: config.metadataPrefix
                        ) {
                            self?.applyMetadata(metadata, tabManager: tabManager)
                        }
                    }
                }
                if newLines.contains(where: {
                    SidebarPromptLauncherTemplateRenderer.isCompletionLine($0, patterns: config.completionPatterns)
                }) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    #if DEBUG
                    cmuxDebugLog("promptLauncher.completionPattern matched")
                    #endif
                    resume(RunResult(succeeded: true, message: nil))
                }
            }
            proc.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let status = process.terminationStatus
                #if DEBUG
                cmuxDebugLog("promptLauncher.exit status=\(status)")
                #endif
                let succeeded = status == 0
                let message = succeeded ? nil : currentLatestLine()
                resume(RunResult(succeeded: succeeded, message: message))
            }
            do {
                try proc.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                #if DEBUG
                cmuxDebugLog("promptLauncher.launchError \(error.localizedDescription)")
                #endif
                resume(RunResult(succeeded: false, message: error.localizedDescription))
            }
        }
    }

    private func applyMetadata(
        _ metadata: SidebarPromptLauncherWorkspaceMetadata,
        tabManager: TabManager
    ) {
        guard let workspace = resolveWorkspace(metadata.workspace, tabManager: tabManager) else {
            return
        }
        if let title = metadata.title {
            tabManager.setCustomTitle(tabId: workspace.id, title: title)
        }
        if let description = metadata.description {
            tabManager.setCustomDescription(tabId: workspace.id, description: description)
        }
        if let color = metadata.color,
           let resolvedColor = WorkspaceTabColorSettings.resolvedColorHex(color) {
            tabManager.setTabColor(tabId: workspace.id, color: resolvedColor)
        }
        if let slot = metadata.slot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slot.isEmpty {
            workspace.promptLauncherSlot = slot
        }
    }

    private func resolveWorkspace(
        _ rawHandle: String?,
        tabManager: TabManager
    ) -> Workspace? {
        guard let rawHandle else { return nil }
        let handle = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty else { return nil }
        if let uuid = UUID(uuidString: handle) {
            return tabManager.tabs.first(where: { $0.id == uuid })
        }
        if handle.hasPrefix("workspace:") {
            let suffix = String(handle.dropFirst("workspace:".count))
            if let uuid = UUID(uuidString: suffix) {
                return tabManager.tabs.first(where: { $0.id == uuid })
            }
            if let index = Int(suffix), index > 0, index <= tabManager.tabs.count {
                return tabManager.tabs[index - 1]
            }
        }
        if let index = Int(handle), index > 0, index <= tabManager.tabs.count {
            return tabManager.tabs[index - 1]
        }
        return nil
    }
}
