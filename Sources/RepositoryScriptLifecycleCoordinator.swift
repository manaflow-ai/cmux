import Bonsplit
import CmuxFoundation
import CmuxSettings
import Foundation
import UserNotifications

@MainActor
final class RepositoryScriptLifecycleCoordinator {
    private var authorizedResolutions: [UUID: RepositoryScriptResolution] = [:]
    private var activeWorkspaceIDs: Set<UUID> = []
    private var pendingAuthorizations: [String: [() -> Void]] = [:]
    private let configStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let promptStore: RepositorySetupPromptStore
    private let resolver: RepositoryScriptResolver
    private let archiveRunner: RepositoryArchiveScriptRunner

    init(
        configStore: JSONConfigStore,
        catalog: SettingCatalog,
        promptStore: RepositorySetupPromptStore,
        commandRunner: any CommandRunning,
        resolver: RepositoryScriptResolver = RepositoryScriptResolver()
    ) {
        self.configStore = configStore
        self.catalog = catalog
        self.promptStore = promptStore
        self.resolver = resolver
        self.archiveRunner = RepositoryArchiveScriptRunner(commands: commandRunner)
    }

    func workspaceCreated(_ workspace: Workspace, directory: String) {
        guard !workspace.isRemoteTmuxMirror,
              activeWorkspaceIDs.insert(workspace.id).inserted else { return }
        let preferences = configStore.snapshotValue(for: catalog.terminal.repositoryScripts)
        guard let resolution = resolver.resolve(
            directory: directory,
            preferences: preferences
        ) else {
            activeWorkspaceIDs.remove(workspace.id)
            return
        }

        if resolution.shouldPromptForSetup {
            promptStore.show(
                RepositorySetupPrompt(workspaceID: workspace.id, resolution: resolution)
            )
        }

        if let descriptor = resolver.trustDescriptor(for: resolution) {
            requestAuthorization(descriptor, resolution: resolution, workspace: workspace)
        } else {
            authorize(resolution, for: workspace)
        }
    }

    func savedCommand(named name: String?) -> String? {
        let library = configStore.snapshotValue(for: catalog.terminal.savedCommands)
        return library.command(named: name)?.command
    }

    func workspaceWillClose(_ workspace: Workspace) {
        activeWorkspaceIDs.remove(workspace.id)
        promptStore.remove(workspaceID: workspace.id)
        guard let resolution = authorizedResolutions.removeValue(forKey: workspace.id),
              let archive = resolution.archive else { return }
        let repositoryName = URL(fileURLWithPath: resolution.identity.workTreeRoot).lastPathComponent
        Task { [weak self, archiveRunner] in
            let result = await archiveRunner.run(archive, in: resolution.identity.workTreeRoot)
            guard let self else { return }
            postArchiveResult(result, repositoryName: repositoryName)
        }
    }

    func workspacesWillClose(_ workspaces: [Workspace]) {
        for workspace in workspaces {
            workspaceWillClose(workspace)
        }
    }

    private func authorize(_ resolution: RepositoryScriptResolution, for workspace: Workspace) {
        guard activeWorkspaceIDs.contains(workspace.id) else { return }
        authorizedResolutions[workspace.id] = resolution
        guard let setup = resolution.setup else { return }
        launchSetup(setup, in: resolution.identity.workTreeRoot, workspace: workspace)
    }

    private func requestAuthorization(
        _ descriptor: CmuxActionTrustDescriptor,
        resolution: RepositoryScriptResolution,
        workspace: Workspace
    ) {
        let fingerprint = descriptor.fingerprint
        let authorizeWorkspace = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            authorize(resolution, for: workspace)
        }
        if pendingAuthorizations[fingerprint] != nil {
            pendingAuthorizations[fingerprint, default: []].append(authorizeWorkspace)
            return
        }
        pendingAuthorizations[fingerprint] = [authorizeWorkspace]

        let projectConfigPath: String?
        if case .projectFile(let path) = resolution.source {
            projectConfigPath = path
        } else {
            projectConfigPath = nil
        }
        CmuxConfigExecutor.authorizeProjectAutomationIfNeeded(
            descriptor: descriptor,
            confirm: false,
            configSourcePath: projectConfigPath,
            globalConfigPath: configStore.fileURL.path,
            displayCommand: resolver.trustDisplayCommand(for: resolution),
            displayTitle: String(
                localized: "dialog.repositoryScripts.trust.title",
                defaultValue: "Trust Repository Scripts?"
            ),
            onAuthorized: { [weak self] in
                guard let callbacks = self?.pendingAuthorizations.removeValue(forKey: fingerprint) else {
                    return
                }
                callbacks.forEach { $0() }
            },
            onDenied: { [weak self] in
                self?.pendingAuthorizations.removeValue(forKey: fingerprint)
            }
        )
    }

    private func launchSetup(_ script: String, in directory: String, workspace: Workspace) {
        let location = configStore.snapshotValue(for: catalog.terminal.setupScriptLocation)
        let panel: TerminalPanel?
        switch RepositorySetupLaunchPlan(location: location) {
        case .backgroundTab:
            guard let paneID = workspace.bonsplitController.focusedPaneId else { return }
            panel = workspace.newTerminalSurface(
                inPane: paneID,
                focus: false,
                workingDirectory: directory,
                initialInput: nil,
                preserveFocusWhenUnfocused: true,
                allowTextBoxFocusDefault: false
            )
            if let panel {
                panel.submitCommand(script)
            }
        case .split(let orientation):
            guard let anchor = workspace.focusedPanelId else { return }
            panel = workspace.newTerminalSplit(
                from: anchor,
                orientation: orientation,
                focus: false,
                workingDirectory: directory,
                allowTextBoxFocusDefault: false
            )
            panel?.submitCommand(script)
        }
        if let panel {
            _ = workspace.setPanelCustomTitle(
                panelId: panel.id,
                title: String(localized: "terminal.repositorySetup.title", defaultValue: "Setup")
            )
        }
    }

    private func postArchiveResult(_ result: CommandResult, repositoryName: String) {
        let succeeded = result.executionError == nil && !result.timedOut && result.exitStatus == 0
        let content = UNMutableNotificationContent()
        content.title = succeeded
            ? String(localized: "notification.repositoryArchive.success", defaultValue: "Archive Script Finished")
            : String(localized: "notification.repositoryArchive.failure", defaultValue: "Archive Script Failed")
        if succeeded {
            let format = String(
                localized: "notification.repositoryArchive.success.body",
                defaultValue: "%@ cleanup completed."
            )
            content.body = String(format: format, repositoryName)
        } else if let executionError = result.executionError {
            let format = String(
                localized: "notification.repositoryArchive.launchFailure.body",
                defaultValue: "%@ cleanup couldn't start: %@"
            )
            content.body = String(format: format, repositoryName, executionError)
        } else {
            let format = String(
                localized: "notification.repositoryArchive.failure.body",
                defaultValue: "%@ cleanup exited with status %d."
            )
            content.body = String(format: format, repositoryName, result.exitStatus ?? -1)
        }
        let request = UNNotificationRequest(
            identifier: "cmux.repository-archive.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
