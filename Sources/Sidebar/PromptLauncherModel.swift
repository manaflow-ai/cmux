import Foundation
import Observation
import CmuxSettings
import CmuxSidebar

@MainActor
@Observable final class PromptLauncherModel {
    struct Job: Identifiable {
        enum State: Equatable {
            case starting
            case waitingForWorkspace
            case attached
            case failed
        }

        let id: UUID
        let prompt: String
        let targetID: String
        let providerID: String
        let repositoryID: String?
        var state: State
        var latestLine: String
        var workspaceID: UUID?
        var usesStructuredLifecycle: Bool
    }

    struct CloseJob: Identifiable {
        enum State: Equatable {
            case running
            case failed
        }

        let id: UUID
        let workspaceName: String
        let shellCommand: String
        let environment: [String: String]
        let forwardedSocketPath: String?
        var state: State
        var latestLine: String
    }

    var promptText = ""
    var selectedTarget = ""
    var selectedProvider = ""
    var selectedRepository = ""
    private(set) var jobs: [Job] = []
    private(set) var closeJobs: [CloseJob] = []

    private let commandRunner: any PromptLauncherCommandRunning

    var visibleJobs: [Job] {
        jobs.filter { $0.state != .attached || $0.usesStructuredLifecycle }
    }

    init(commandRunner: any PromptLauncherCommandRunning = PromptLauncherProcessRunner()) {
        self.commandRunner = commandRunner
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
        guard !prompt.isEmpty else { return }
        launch(
            prompt: prompt,
            targetID: selectedTarget,
            providerID: selectedProvider,
            repositoryID: config.repositories.isEmpty ? nil : selectedRepository,
            config: config,
            tabManager: tabManager,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath
        )
    }

    func retry(
        _ job: Job,
        config: CmuxPromptLauncherDefinition,
        tabManager: TabManager,
        configSourcePath: String?,
        globalConfigPath: String
    ) {
        dismiss(job)
        launch(
            prompt: job.prompt,
            targetID: job.targetID,
            providerID: job.providerID,
            repositoryID: job.repositoryID,
            config: config,
            tabManager: tabManager,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath
        )
    }

    func dismiss(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
    }

    func enqueueClose(
        workspaceName: String,
        shellCommand: String,
        environment: [String: String],
        forwardedSocketPath: String?
    ) {
        let job = CloseJob(
            id: UUID(),
            workspaceName: workspaceName,
            shellCommand: shellCommand,
            environment: environment,
            forwardedSocketPath: forwardedSocketPath,
            state: .running,
            latestLine: String(localized: "sidebar.prompt_launcher.closing", defaultValue: "Closing workspace…")
        )
        closeJobs.append(job)
        runClose(job)
    }

    func retry(_ job: CloseJob) {
        guard let index = closeJobs.firstIndex(where: { $0.id == job.id }) else { return }
        closeJobs[index].state = .running
        closeJobs[index].latestLine = String(
            localized: "sidebar.prompt_launcher.closing",
            defaultValue: "Closing workspace…"
        )
        runClose(closeJobs[index])
    }

    func dismiss(_ job: CloseJob) {
        closeJobs.removeAll { $0.id == job.id }
    }

    private func launch(
        prompt: String,
        targetID: String,
        providerID: String,
        repositoryID: String?,
        config: CmuxPromptLauncherDefinition,
        tabManager: TabManager,
        configSourcePath: String?,
        globalConfigPath: String
    ) {
        guard let shellCommand = SidebarPromptLauncherTemplateRenderer.renderCommand(
            config: config,
            targetID: targetID,
            providerID: providerID,
            repositoryID: repositoryID,
            prompt: prompt
        ) else { return }

        CmuxConfigExecutor.authorizePromptLauncherIfNeeded(
            promptLauncher: config,
            renderedCommand: shellCommand,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath
        ) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            self.startLaunch(
                shellCommand: shellCommand,
                config: config,
                prompt: prompt,
                targetID: targetID,
                providerID: providerID,
                repositoryID: repositoryID,
                tabManager: tabManager
            )
        }
    }

    private func startLaunch(
        shellCommand: String,
        config: CmuxPromptLauncherDefinition,
        prompt: String,
        targetID: String,
        providerID: String,
        repositoryID: String?,
        tabManager: TabManager
    ) {
        let jobID = UUID()
        jobs.append(Job(
            id: jobID,
            prompt: prompt,
            targetID: targetID,
            providerID: providerID,
            repositoryID: repositoryID,
            state: .starting,
            latestLine: String(localized: "sidebar.prompt_launcher.starting", defaultValue: "Starting…"),
            workspaceID: nil,
            usesStructuredLifecycle: false
        ))
        if promptText.trimmingCharacters(in: .whitespacesAndNewlines) == prompt {
            promptText = ""
        }

        Task { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            let stream = await commandRunner.events(
                shellCommand: shellCommand,
                environment: config.environment,
                forwardedSocketPath: config.forwardCmuxSocket ? SocketControlSettings.socketPath() : nil
            )
            var receivedTerminalEvent = false
            for await event in stream {
                switch event {
                case let .output(line):
                    handleLaunchOutput(line, jobID: jobID, config: config, tabManager: tabManager)
                    if SidebarPromptLauncherTemplateRenderer.isCompletionLine(
                        line,
                        patterns: config.completionPatterns
                    ), jobs.first(where: { $0.id == jobID })?.usesStructuredLifecycle != true {
                        jobs.removeAll { $0.id == jobID }
                        return
                    }
                case let .finished(exitStatus):
                    receivedTerminalEvent = true
                    finishLaunch(jobID: jobID, exitStatus: exitStatus, errorMessage: nil, tabManager: tabManager)
                case let .failed(message):
                    receivedTerminalEvent = true
                    finishLaunch(jobID: jobID, exitStatus: nil, errorMessage: message, tabManager: tabManager)
                }
            }
            if !receivedTerminalEvent, jobs.contains(where: { $0.id == jobID }) {
                finishLaunch(jobID: jobID, exitStatus: nil, errorMessage: nil, tabManager: tabManager)
            }
        }
    }

    private func handleLaunchOutput(
        _ line: String,
        jobID: UUID,
        config: CmuxPromptLauncherDefinition,
        tabManager: TabManager
    ) {
        updateJob(jobID) { job in
            job.latestLine = line
            if job.state == .starting {
                job.state = .waitingForWorkspace
            }
        }
        if let metadata = SidebarPromptLauncherTemplateRenderer.metadata(from: line, prefix: config.metadataPrefix) {
            applyMetadata(metadata, jobID: jobID, tabManager: tabManager)
        }
    }

    private func finishLaunch(
        jobID: UUID,
        exitStatus: Int32?,
        errorMessage: String?,
        tabManager: TabManager
    ) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        if exitStatus == 0, !job.usesStructuredLifecycle {
            jobs.removeAll { $0.id == jobID }
            return
        }

        let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let latestLine = job.latestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workspaceID = job.workspaceID,
           let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) {
            workspace.statusEntries["workflow"] = SidebarStatusEntry(
                key: "workflow",
                value: String(localized: "sidebar.sessionGroup.needsAttention", defaultValue: "Needs Attention"),
                icon: "exclamationmark.triangle.fill",
                color: "#E74C3C",
                priority: 100,
                timestamp: Date()
            )
            jobs.removeAll { $0.id == jobID }
            return
        }

        updateJob(jobID) { failedJob in
            failedJob.state = .failed
            failedJob.latestLine = message.flatMap { $0.isEmpty ? nil : $0 }
                ?? (latestLine.isEmpty ? String(
                    localized: "sidebar.prompt_launcher.failed",
                    defaultValue: "Prompt launcher failed"
                ) : latestLine)
        }
    }

    private func runClose(_ job: CloseJob) {
        Task { [weak self] in
            guard let self else { return }
            let stream = await commandRunner.events(
                shellCommand: job.shellCommand,
                environment: job.environment,
                forwardedSocketPath: job.forwardedSocketPath
            )
            var receivedTerminalEvent = false
            for await event in stream {
                guard let index = closeJobs.firstIndex(where: { $0.id == job.id }) else { return }
                switch event {
                case let .output(line):
                    closeJobs[index].latestLine = line
                case let .finished(exitStatus):
                    receivedTerminalEvent = true
                    if exitStatus == 0 {
                        closeJobs.remove(at: index)
                    } else {
                        failClose(at: index, message: nil)
                    }
                case let .failed(message):
                    receivedTerminalEvent = true
                    failClose(at: index, message: message)
                }
            }
            if !receivedTerminalEvent,
               let index = closeJobs.firstIndex(where: { $0.id == job.id }) {
                failClose(at: index, message: nil)
            }
        }
    }

    private func failClose(at index: Int, message: String?) {
        closeJobs[index].state = .failed
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let latestLine = closeJobs[index].latestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            closeJobs[index].latestLine = message
        } else if latestLine.isEmpty || latestLine == String(
            localized: "sidebar.prompt_launcher.closing",
            defaultValue: "Closing workspace…"
        ) {
            closeJobs[index].latestLine = String(
                localized: "sidebar.prompt_launcher.close_failed",
                defaultValue: "Workspace cleanup failed"
            )
        }
    }

    private func updateJob(_ id: UUID, update: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        update(&jobs[index])
    }

    private func applyMetadata(
        _ metadata: SidebarPromptLauncherWorkspaceMetadata,
        jobID: UUID,
        tabManager: TabManager
    ) {
        if metadata.phase != nil {
            updateJob(jobID) { $0.usesStructuredLifecycle = true }
        }
        guard let workspace = resolveWorkspace(metadata.workspace, tabManager: tabManager) else { return }
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
        if let slot = metadata.slot?.trimmingCharacters(in: .whitespacesAndNewlines), !slot.isEmpty {
            workspace.promptLauncherSlot = slot
        }
        updateJob(jobID) { job in
            job.workspaceID = workspace.id
            job.state = .attached
        }
        if metadata.phase == .ready {
            jobs.removeAll { $0.id == jobID }
        }
    }

    private func resolveWorkspace(_ rawHandle: String?, tabManager: TabManager) -> Workspace? {
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
