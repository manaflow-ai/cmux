import Bonsplit
import CmuxFoundation
import CmuxSettings
import Foundation
import UserNotifications

@MainActor
final class RepositoryScriptLifecycleCoordinator {
    private var workspaceStates: [UUID: RepositoryScriptWorkspaceLifecycleState] = [:]
    private var pendingAuthorizations: [String: Set<UUID>] = [:]
    private let configStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let promptStore: RepositorySetupPromptStore
    private let resolver: RepositoryScriptResolver
    private let archiveRunner: RepositoryArchiveScriptRunner
    private let authorizer: any RepositoryScriptAuthorizing

    init(
        configStore: JSONConfigStore,
        catalog: SettingCatalog,
        promptStore: RepositorySetupPromptStore,
        commandRunner: any CommandRunning,
        resolver: RepositoryScriptResolver = RepositoryScriptResolver(),
        authorizer: any RepositoryScriptAuthorizing = RepositoryScriptAuthorizationService()
    ) {
        self.configStore = configStore
        self.catalog = catalog
        self.promptStore = promptStore
        self.resolver = resolver
        self.archiveRunner = RepositoryArchiveScriptRunner(commands: commandRunner)
        self.authorizer = authorizer
    }

    func workspaceCreated(_ workspace: Workspace, directory: String) {
        guard !workspace.isRemoteTmuxMirror,
              workspaceStates[workspace.id] == nil else { return }
        workspaceStates[workspace.id] = .resolving(workspace: workspace)
        let preferences = configStore.snapshotValue(for: catalog.terminal.repositoryScripts)
        let workspaceID = workspace.id
        let resolver = resolver
        Task { @MainActor [weak self] in
            let resolution = await resolver.resolve(
                directory: directory,
                preferences: preferences
            )
            self?.didResolve(resolution, workspaceID: workspaceID)
        }
    }

    func savedCommand(named name: String?) -> String? {
        let library = configStore.snapshotValue(for: catalog.terminal.savedCommands)
        return library.command(named: name)?.command
    }

    func workspaceWillClose(_ workspace: Workspace) {
        promptStore.remove(workspaceID: workspace.id)
        guard let state = workspaceStates[workspace.id] else { return }
        switch state {
        case .resolving:
            workspaceStates[workspace.id] = .closingAwaitingResolution
        case .awaitingAuthorization(let resolution, _):
            workspaceStates[workspace.id] = .closingAwaitingAuthorization(
                resolution: resolution
            )
        case .authorized(let resolution):
            workspaceStates.removeValue(forKey: workspace.id)
            runArchive(for: resolution)
        case .closingAwaitingResolution, .closingAwaitingAuthorization:
            break
        }
    }

    func workspacesWillClose(_ workspaces: [Workspace]) {
        for workspace in workspaces {
            workspaceWillClose(workspace)
        }
    }

    private func didResolve(_ resolution: RepositoryScriptResolution?, workspaceID: UUID) {
        guard let state = workspaceStates[workspaceID] else { return }
        switch state {
        case .resolving(let workspace):
            guard let resolution else {
                workspaceStates.removeValue(forKey: workspaceID)
                return
            }
            if resolution.shouldPromptForSetup {
                promptStore.show(
                    RepositorySetupPrompt(workspaceID: workspaceID, resolution: resolution)
                )
            }
            if let descriptor = resolver.trustDescriptor(for: resolution) {
                workspaceStates[workspaceID] = .awaitingAuthorization(
                    resolution: resolution,
                    workspace: workspace
                )
                requestAuthorization(
                    descriptor,
                    resolution: resolution,
                    workspaceID: workspaceID
                )
            } else {
                workspaceStates[workspaceID] = .authorized(resolution: resolution)
                launchSetupIfPresent(resolution, workspace: workspace)
            }
        case .closingAwaitingResolution:
            workspaceStates.removeValue(forKey: workspaceID)
            guard let resolution else { return }
            if let descriptor = resolver.trustDescriptor(for: resolution),
               !authorizer.isTrusted(descriptor) {
                return
            }
            runArchive(for: resolution)
        case .awaitingAuthorization, .authorized, .closingAwaitingAuthorization:
            break
        }
    }

    private func completeAuthorization(workspaceID: UUID) {
        guard let state = workspaceStates[workspaceID] else { return }
        switch state {
        case .awaitingAuthorization(let resolution, let workspace):
            workspaceStates[workspaceID] = .authorized(resolution: resolution)
            launchSetupIfPresent(resolution, workspace: workspace)
        case .closingAwaitingAuthorization(let resolution):
            workspaceStates.removeValue(forKey: workspaceID)
            runArchive(for: resolution)
        case .resolving, .authorized, .closingAwaitingResolution:
            break
        }
    }

    private func denyAuthorization(workspaceID: UUID) {
        guard let state = workspaceStates[workspaceID] else { return }
        switch state {
        case .awaitingAuthorization, .closingAwaitingAuthorization:
            workspaceStates.removeValue(forKey: workspaceID)
        case .resolving, .authorized, .closingAwaitingResolution:
            break
        }
    }

    private func launchSetupIfPresent(
        _ resolution: RepositoryScriptResolution,
        workspace: Workspace
    ) {
        guard let setup = resolution.setup else { return }
        launchSetup(setup, in: resolution.identity.workTreeRoot, workspace: workspace)
    }

    private func requestAuthorization(
        _ descriptor: CmuxActionTrustDescriptor,
        resolution: RepositoryScriptResolution,
        workspaceID: UUID
    ) {
        let fingerprint = descriptor.fingerprint
        if pendingAuthorizations[fingerprint] != nil {
            pendingAuthorizations[fingerprint, default: []].insert(workspaceID)
            return
        }
        pendingAuthorizations[fingerprint] = [workspaceID]

        let projectConfigPath: String?
        if case .projectFile(let path) = resolution.source {
            projectConfigPath = path
        } else {
            projectConfigPath = nil
        }
        authorizer.authorize(
            descriptor: descriptor,
            configSourcePath: projectConfigPath,
            globalConfigPath: configStore.fileURL.path,
            displayCommand: resolver.trustDisplayCommand(for: resolution),
            displayTitle: String(
                localized: "dialog.repositoryScripts.trust.title",
                defaultValue: "Trust Repository Scripts?"
            ),
            onAuthorized: { [weak self] in
                guard let self,
                      let workspaceIDs = pendingAuthorizations.removeValue(forKey: fingerprint) else {
                    return
                }
                workspaceIDs.forEach { self.completeAuthorization(workspaceID: $0) }
            },
            onDenied: { [weak self] in
                guard let self,
                      let workspaceIDs = pendingAuthorizations.removeValue(forKey: fingerprint) else {
                    return
                }
                workspaceIDs.forEach { self.denyAuthorization(workspaceID: $0) }
            }
        )
    }

    private func runArchive(for resolution: RepositoryScriptResolution) {
        guard let archive = resolution.archive else { return }
        let repositoryName = URL(fileURLWithPath: resolution.identity.workTreeRoot).lastPathComponent
        Task { [weak self, archiveRunner] in
            let result = await archiveRunner.run(archive, in: resolution.identity.workTreeRoot)
            guard let self else { return }
            postArchiveResult(result, repositoryName: repositoryName)
        }
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
            content.body = String.localizedStringWithFormat(format, repositoryName)
        } else if let executionError = result.executionError {
            #if DEBUG
            cmuxDebugLog(
                "repositoryArchive.launch.failed repository=\(repositoryName) error=\(executionError)"
            )
            #endif
            let format = String(
                localized: "notification.repositoryArchive.launchFailure.body",
                defaultValue: "%@ cleanup couldn't start."
            )
            content.body = String.localizedStringWithFormat(format, repositoryName)
        } else if result.timedOut {
            let format = String(
                localized: "notification.repositoryArchive.timeout.body",
                defaultValue: "%@ cleanup timed out after 5 minutes."
            )
            content.body = String.localizedStringWithFormat(format, repositoryName)
        } else {
            let format = String(
                localized: "notification.repositoryArchive.failure.body",
                defaultValue: "%@ cleanup exited with status %d."
            )
            content.body = String.localizedStringWithFormat(
                format,
                repositoryName,
                result.exitStatus ?? -1
            )
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
