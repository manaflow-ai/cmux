import AppKit
import Foundation

// MARK: - New Cloud Workspace (Cmd+Y)

extension AppDelegate {
    @discardableResult
    func performNewWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        debugSource: String = "newWorkspace",
        skipConfiguredAction: Bool = false
    ) -> Bool {
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? event.flatMap { mainWindowContext(forShortcutEvent: $0, debugSource: debugSource) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        if let context {
            let target = newWorkspaceMachineContext(for: context).target
            if case .unavailable = target {
                NSSound.beep()
                return false
            }
            guard case .cloud(let machineID) = target else {
                return performNewWorkspaceCreationAction(
                    initialSurface: .terminal,
                    preferredTabManager: preferredTabManager,
                    event: event,
                    debugSource: debugSource,
                    skipConfiguredAction: skipConfiguredAction
                )
            }
            // A configured command/action is an intentional override. The
            // built-in New Workspace action remains eligible for machine
            // routing; explicit Cloud/local commands keep their semantics.
            let hasExplicitConfiguredAction: Bool = {
                guard !skipConfiguredAction else { return false }
                guard let action = context.cmuxConfigStore?.resolvedNewWorkspaceAction() else { return false }
                if case .builtIn(.newWorkspace) = action.action { return false }
                return true
            }()
            if !hasExplicitConfiguredAction {
                let destination: CloudWorkspaceGroupDestination? = {
                    guard context.tabManager.selectedWorkspace?.cloudVMBinding?.vmID == machineID,
                          let group = workspaceGroupNewWorkspaceTarget(in: context) else { return nil }
                    return CloudWorkspaceGroupDestination(
                        tabManager: context.tabManager,
                        groupId: group.groupId,
                        placement: group.placement,
                        referenceWorkspaceId: group.referenceWorkspaceId,
                        initialWorkspaceId: nil
                    )
                }()
                return performNewCloudWorkspaceOnMachineAction(
                    machineID: machineID,
                    focus: context.tabManager.selectedTabId != nil,
                    windowID: context.windowId,
                    destination: destination,
                    debugSource: debugSource
                )
            }
        }
        return performNewWorkspaceCreationAction(
            initialSurface: .terminal,
            preferredTabManager: preferredTabManager,
            event: event,
            debugSource: debugSource,
            skipConfiguredAction: skipConfiguredAction
        )
    }

    /// Records the Machines tree selection for the owning window. The active
    /// focus coordinator decides later whether this selection is authoritative.
    func setNewWorkspaceMachineSelection(_ selection: NewWorkspaceMachineContext.Selection, in tabManager: TabManager?) {
        guard let tabManager,
              let context = mainWindowContext(for: tabManager) else { return }
        context.newWorkspaceMachineSelection = selection
    }

    /// Resolves the target before any async Cloud operation starts.
    func newWorkspaceMachineContext(for context: MainWindowContext) -> NewWorkspaceMachineContext {
        NewWorkspaceMachineContext(
            selection: context.newWorkspaceMachineSelection,
            selectedWorkspaceCloudMachineID: context.tabManager.selectedWorkspace?.cloudVMBinding?.vmID,
            machinesPanelOwnsFocus: context.keyboardFocusCoordinator.activeRightSidebarMode == .machines
        )
    }

    /// Creates and opens a new workspace on a captured Cloud machine. The
    /// machine id is part of the keyed operation's closure, so a later sidebar
    /// selection change cannot retarget the request or fall back to local PTYs.
    @discardableResult
    func performNewCloudWorkspaceOnMachineAction(
        machineID: String,
        focus: Bool,
        windowID: UUID? = nil,
        destination: CloudWorkspaceGroupDestination? = nil,
        debugSource: String = "newWorkspace.cloud"
    ) -> Bool {
        guard let coordinator = cloudWorkspaceCoordinator,
              let operationController = cloudWorkspaceOperationController,
              coordinator.isAvailable else { return false }
        let capturedMachineID = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedMachineID.isEmpty else { return false }
        return operationController.start(key: "new-cloud-workspace", {
            guard let workspaceID = try await coordinator.createOnMachine(
                machineID: capturedMachineID, focus: focus, windowID: windowID
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
        // Cmd+Y is one logical create-and-open intent. Coalesce repeated key
        // events while the remote receipt is still being discovered/attached.
        return operationController.start(key: "new-cloud-workspace") {
            guard let workspaceID = try await coordinator.createOnDefaultMachine(focus: focus),
                  !Task.isCancelled,
                  coordinator.isAvailable else { return }
            destination?.apply(workspaceID: workspaceID)
        }
    }

    /// Presents machine provisioning and applies its exact workspace receipt to a group when requested.
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
            guard let workspaceID = await presenter.presentNewMachineFetchingPlan(preferredWindow: hostWindow),
                  !Task.isCancelled,
                  operationController.isCurrentlyAvailable else { return }
            destination?.apply(workspaceID: workspaceID)
        }
    }
}
