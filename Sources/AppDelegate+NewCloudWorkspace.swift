import AppKit
import CmuxSettings
import Foundation

// MARK: - Cloud creation actions

extension AppDelegate {
    /// Creates a workspace on the persisted default machine through the app-owned operation controller.
    @discardableResult
    func performNewCloudWorkspaceOnDefaultMachineAction(
        preferredWindow: NSWindow? = nil,
        debugSource: String = "newCloudWorkspace",
        destination: CloudWorkspaceGroupDestination? = nil
    ) -> Bool {
        guard let coordinator = cloudWorkspaceCoordinator,
              let operationController = cloudWorkspaceOperationController,
              coordinator.isAvailable else { return false }
        let context = preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        let focus = context?.tabManager.selectedTabId != nil
        // Default-machine creation is one logical intent. Coalesce repeated key
        // events while the remote receipt is still being discovered/attached.
        return operationController.start(key: "new-cloud-workspace.default") {
            guard let workspaceID = try await coordinator.createOnDefaultMachine(focus: focus),
                  !Task.isCancelled,
                  coordinator.isAvailable else { return }
            destination?.apply(workspaceID: workspaceID)
        }
    }

    /// Creates on the VM captured by the shared New Workspace action.
    @discardableResult
    func performNewCloudWorkspaceOnCurrentMachineAction(
        tabManager: TabManager,
        vmID: String,
        destination: CloudWorkspaceGroupDestination? = nil
    ) -> Bool {
        guard let coordinator = cloudWorkspaceCoordinator,
              let operationController = cloudWorkspaceOperationController,
              coordinator.isAvailable else { return false }
        let resolvedDestination = destination ?? mainWindowContext(for: tabManager).flatMap { context in
            guard let target = workspaceGroupNewWorkspaceTarget(in: context) else { return nil }
            return CloudWorkspaceGroupDestination(
                tabManager: tabManager,
                groupId: target.groupId,
                placement: target.placement,
                referenceWorkspaceId: target.referenceWorkspaceId,
                initialWorkspaceId: nil
            )
        }
        return operationController.start(key: "new-cloud-workspace.\(vmID)") {
            guard let workspaceID = try await coordinator.createOnMachine(id: vmID, focus: true),
                  !Task.isCancelled, coordinator.isAvailable else { return }
            resolvedDestination?.apply(workspaceID: workspaceID)
        }
    }

    /// Places a machine's reservation immediately; later provisioning cannot undo user navigation.
    @discardableResult
    func performNewCloudWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "newCloudWorkspace",
        destination: CloudWorkspaceGroupDestination? = nil
    ) -> Bool {
        guard let operationController = cloudWorkspaceOperationController,
              operationController.isCurrentlyAvailable else { return false }
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? preferredWindow.flatMap { contextForMainWindow($0) }
            ?? event.flatMap { mainWindowContext(forShortcutEvent: $0, debugSource: debugSource) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        let hostWindow = context.flatMap { resolvedWindow(for: $0) }
            ?? preferredWindow ?? event?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let presenter = newMachineSheetPresenter else { return false }
        return operationController.start {
            _ = await presenter.presentNewMachineFetchingPlan(preferredWindow: hostWindow) { workspaceID in
                guard operationController.isCurrentlyAvailable else { return }
                destination?.apply(workspaceID: workspaceID)
            }
        }
    }
}

// MARK: - One create path for every flow


extension AppDelegate {
    /// Runs the launcher that every placeholder-filling create uses; tests
    /// swap it for a recorder.
    typealias CloudMachineCreateLaunch = @MainActor (
        _ workspace: Workspace,
        _ arguments: [String],
        _ progress: @escaping @MainActor (String) -> Void,
        _ cancellationReady: @escaping @MainActor (CloudVMActionLauncher.CancellationHandle) -> Void,
        _ completion: @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void
    ) -> Bool

    @MainActor
    static var cloudMachineCreateLaunchOverride: CloudMachineCreateLaunch?

    /// Starts a machine create (`vm new`, `vm fork`) the way the person
    /// experiences it: a workspace with a loading pane appears at once, the
    /// Machines panel gets a pending row, and the CLI fills the pane in when
    /// the machine is reachable. Cancel from the row closes the workspace;
    /// a failure shows in the pane with Retry, and a machine that was minted
    /// but could not be opened points at the Machines panel instead of
    /// minting a second one.
    ///
    /// Returns false when nothing could start (no window, launcher refused);
    /// the placeholder is taken down again in that case.
    @discardableResult
    func startCloudMachineCreate(
        _ request: MachineCreateRequest,
        tabManager preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow?,
        coordinator suppliedCoordinator: MachineCreateCoordinator? = nil,
        debugSource: String = "cloudVM.create"
    ) -> Bool {
        let coordinator = suppliedCoordinator ?? .shared
        guard let prepared = prepareCloudMachineCreate(request, tabManager: preferredTabManager, preferredWindow: preferredWindow, debugSource: debugSource) else { return false }
        let (boundRequest, workspace, tabManager, launch) = prepared
        let didStart = coordinator.start(boundRequest, cancellableLaunch: launch)
        guard didStart else {
            tabManager.closeWorkspace(workspace, recordHistory: false)
            return false
        }
        installCloudMachineCreateRetry(workspace: workspace, coordinator: coordinator)
        return true
    }

    /// Keeps the command controller's cancellation and exact workspace receipt
    /// while using the same placeholder launcher as the panel and RPC paths.
    func startCloudMachineCreateAndAwaitWorkspaceID(
        _ request: MachineCreateRequest,
        preferredWindow: NSWindow?,
        coordinator: MachineCreateCoordinator,
        onReservation: (@MainActor (UUID) -> Void)? = nil
    ) async -> UUID? {
        guard let prepared = prepareCloudMachineCreate(request, preferredWindow: preferredWindow) else { return nil }
        let (boundRequest, workspace, tabManager, launch) = prepared
        onReservation?(workspace.id)
        installCloudMachineCreateRetry(workspace: workspace, coordinator: coordinator)
        let result = await coordinator.startAndAwaitWorkspaceID(boundRequest, cancellableLaunch: launch)
        if result == nil, !coordinator.operations.contains(where: { $0.request.placeholderWorkspaceID == workspace.id }), cloudVMLoadingPanel(in: workspace)?.hasFailed != true {
            tabManager.closeWorkspace(workspace, recordHistory: false)
        }
        return result
    }

    private func prepareCloudMachineCreate(
        _ request: MachineCreateRequest,
        tabManager preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow?,
        debugSource: String = "cloudVM.create"
    ) -> (MachineCreateRequest, Workspace, TabManager, MachineCreateCoordinator.CancellableLaunch)? {
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        guard let context else {
            NSSound.beep()
            return nil
        }
        let tabManager = context.tabManager
        guard let workspace = makeCloudVMPlaceholderWorkspace(
            in: tabManager,
            title: request.displayName,
            flow: request.loadingFlow,
            pinned: request.isBaseSetup
        ) else { return nil }
        let boundRequest = request.withPlaceholder(workspaceID: workspace.id)
        let launchWindow = resolvedWindow(for: context) ?? preferredWindow
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let launch: CloudMachineCreateLaunch = Self.cloudMachineCreateLaunchOverride ?? { [weak self] workspace, arguments, progress, cancellationReady, completion in
            guard let self else { return false }
            return self.launchCloudVMIntoLoadingWorkspace(
                workspace: workspace,
                socketPath: socketPath,
                preferredWindow: launchWindow,
                arguments: arguments,
                onProgress: progress,
                onCancellationReady: cancellationReady,
                onCompletion: completion
            )
        }
        let cancellableLaunch: MachineCreateCoordinator.CancellableLaunch = { [weak workspace] arguments, progress, completion in
            guard let workspace else { return nil }
            var cancellation: CloudVMActionLauncher.CancellationHandle?
            let didLaunch = launch(workspace, arguments, progress, { cancellation = $0 }, { [weak self] result in
                if !result.succeeded, !result.wasCancelled,
                   let panel = self?.cloudVMLoadingPanel(in: workspace) {
                    let machineID = result.machineId
                        ?? MachineCreateCoordinator.createdMachineID(fromOutput: result.output)
                    if !boundRequest.isBaseSetup, machineID != nil {
                        // The machine exists; a retry would mint another.
                        panel.canRetry = false
                        panel.retryHandler = nil
                        panel.showFailure(String(
                            localized: "panel.cloudVM.loading.failed.createdOpenFailed",
                            defaultValue: "The machine was created but could not be opened here. Open it from the Machines panel."
                        ))
                    }
                }
                completion(result)
            })
            return didLaunch ? cancellation : nil
        }
        return (boundRequest, workspace, tabManager, cancellableLaunch)
    }

    private func installCloudMachineCreateRetry(workspace: Workspace, coordinator: MachineCreateCoordinator) {
        let workspaceID = workspace.id
        if let panel = cloudVMLoadingPanel(in: workspace), panel.canRetry {
            panel.retryHandler = { [weak coordinator] in
                guard let coordinator,
                      let operation = coordinator.operations.first(where: {
                          $0.request.placeholderWorkspaceID == workspaceID
                      }) else { return }
                _ = coordinator.retry(operation.id)
            }
        }
    }
}
