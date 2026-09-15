import AppKit
import CmuxCloudMachines
import Foundation

// MARK: - New Cloud Workspace (Cmd+Y)

extension AppDelegate {
    /// Records the Machines tree selection for the owning window. The active
    /// focus coordinator decides later whether this selection is authoritative.
    func setCloudTreeSelection(_ selection: CloudTreeSelection, in tabManager: TabManager?) {
        guard let tabManager,
              let context = mainWindowContext(for: tabManager) else { return }
        context.cloudTreeSelection = selection
    }

    func cloudTreeSelection(for tabManager: TabManager?) -> CloudTreeSelection {
        guard let tabManager else { return .empty }
        return mainWindowContext(for: tabManager)?.cloudTreeSelection ?? .empty
    }

    /// Resolves the target before any async Cloud operation starts.
    func newWorkspaceMachineContext(for context: MainWindowContext) -> CloudWorkspaceMachineContext {
        CloudWorkspaceMachineContext(
            selection: context.cloudTreeSelection.machine,
            selectedWorkspaceCloudMachineID: context.tabManager.selectedWorkspace?.cloudVMBinding?.vmID,
            machinesPanelOwnsFocus: context.keyboardFocusCoordinator.activeRightSidebarMode == .machines
        )
    }

    /// Starts one keyed Cloud create on the exact machine captured at the
    /// shortcut boundary. Machine removal fails closed in the coordinator.
    @discardableResult
    func performNewCloudWorkspaceOnMachineAction(
        machineID: String,
        focus: Bool,
        debugSource: String = "newWorkspace.cloud",
        destination: CloudWorkspaceGroupDestination? = nil,
        windowID: UUID? = nil
    ) -> Bool {
        guard let coordinator = cloudWorkspaceCoordinator,
              let operationController = cloudWorkspaceOperationController,
              coordinator.isAvailable else { return false }
        let capturedMachineID = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedMachineID.isEmpty else { return false }
        return operationController.start(key: "new-cloud-workspace.machine:\(capturedMachineID)", {
            guard let workspaceID = try await coordinator.createOnMachine(
                machineID: capturedMachineID,
                focus: focus,
                windowID: windowID
            ), !Task.isCancelled, coordinator.isAvailable else { return }
#if DEBUG
            cmuxDebugLog(
                "newWorkspace.cloud.completed source=\(debugSource) machine=\(capturedMachineID) " +
                    "workspace=\(workspaceID.uuidString.prefix(8))"
            )
#endif
            destination?.apply(workspaceID: workspaceID)
        }, onFailure: { [weak self] error in
            self?.presentCloudWorkspaceCreationFailure(
                machineID: capturedMachineID,
                error: error,
                windowID: windowID,
                retry: { [weak self] in
                    _ = self?.performNewCloudWorkspaceOnMachineAction(
                        machineID: capturedMachineID,
                        focus: focus,
                        windowID: windowID,
                        destination: destination,
                        debugSource: "\(debugSource).retry"
                    )
                }
            )
        })
    }

    private func presentCloudWorkspaceCreationFailure(
        machineID: String,
        error: Error,
        windowID: UUID?,
        retry: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "cloudWorkspace.creation.failed.title",
            defaultValue: "Couldn’t create Cloud workspace"
        )
        let format = String(
            localized: "cloudWorkspace.creation.failed.detail",
            defaultValue: "The workspace could not be created on %@. %@"
        )
        let detail: String = if case CloudWorkspaceCoordinatorError.machineUnavailable = error {
            String(
                localized: "cloudWorkspace.creation.failed.unavailable",
                defaultValue: "The selected Cloud machine is unavailable."
            )
        } else {
            error.localizedDescription
        }
        alert.informativeText = String(format: format, machineID, detail)
        alert.addButton(withTitle: String(localized: "common.retry", defaultValue: "Retry"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        CloudErrorCopy.install(in: alert, text: "\(alert.messageText)\n\(alert.informativeText)")
        let window = windowID.flatMap { id in
            mainWindowContexts.values.first(where: { $0.windowId == id }).flatMap { resolvedWindow(for: $0) }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { retry() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            retry()
        }
    }

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
        let operationKey = coordinator.defaultMachineStore.machineID.map {
            "new-cloud-workspace.machine:\($0)"
        } ?? "new-cloud-workspace.default"
        return operationController.start(key: operationKey) {
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
