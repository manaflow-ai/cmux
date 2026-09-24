import AppKit
import CmuxCloudMachines
import Foundation

// MARK: - Cloud creation actions

extension AppDelegate {
    /// Creates on this window's last Cloud workspace machine, then sidebar order.
    @discardableResult
    func performNewCloudWorkspaceOnResolvedMachineAction(
        tabManager preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "newCloudWorkspace",
        destination: CloudWorkspaceGroupDestination? = nil
    ) -> Bool {
        guard let coordinator = cloudWorkspaceCoordinator,
              let operationController = cloudWorkspaceOperationController,
              coordinator.isAvailable, let scopeID = coordinator.scopeIdentifier else { return false }
        guard let context = preferredTabManager.flatMap({ mainWindowContext(for: $0) })
            ?? preferredWindow.flatMap({ contextForMainWindow($0) })
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource) else { return false }
        let manager = context.tabManager
        manager.recordCloudWorkspaceSelection()
        let selection = manager.rememberedCloudWorkspaceSelection
        let revision = manager.cloudWorkspaceSelection.revision
        let windowID = context.windowId
        return operationController.start(key: "new-cloud-workspace.resolved.\(windowID.uuidString)") { [weak self, weak manager] in
            do {
                guard let workspaceID = try await coordinator.createOnResolvedMachine(
                    selection: selection, windowID: windowID, scopeID: scopeID
                ), !Task.isCancelled, coordinator.isAvailable, coordinator.scopeIdentifier == scopeID else { return }
                destination?.apply(workspaceID: workspaceID)
                self?.focusCreatedCloudWorkspace(workspaceID, manager: manager, revision: revision, windowID: windowID)
            } catch CloudWorkspaceCreationError.noMachines {
                guard !Task.isCancelled, coordinator.scopeIdentifier == scopeID else { return }
                self?.presentNoCloudMachineAvailableAlert(windowID: windowID)
            }
        }
    }

    /// Creates on the machine explicitly selected by Cmd+N and configured New Workspace.
    @discardableResult
    func performNewCloudWorkspaceOnCurrentMachineAction(
        tabManager: TabManager,
        vmID: String,
        destination: CloudWorkspaceGroupDestination? = nil
    ) -> Bool {
        guard let coordinator = cloudWorkspaceCoordinator,
              let operationController = cloudWorkspaceOperationController,
              coordinator.isAvailable, let scopeID = coordinator.scopeIdentifier,
              let context = mainWindowContext(for: tabManager) else { return false }
        let resolvedDestination = destination ?? workspaceGroupNewWorkspaceTarget(in: context).map { target in
            CloudWorkspaceGroupDestination(
                tabManager: tabManager, groupId: target.groupId, placement: target.placement,
                referenceWorkspaceId: target.referenceWorkspaceId, initialWorkspaceId: nil
            )
        }
        let request = CloudWorkspaceCreationRequest(machineID: vmID, scopeID: scopeID, windowID: context.windowId)
        let revision = tabManager.cloudWorkspaceSelection.revision
        return operationController.start(key: "new-cloud-workspace.\(vmID).\(context.windowId.uuidString)") { [weak self, weak tabManager] in
            guard let workspaceID = try await coordinator.createOnMachine(request),
                  !Task.isCancelled, coordinator.isAvailable, coordinator.scopeIdentifier == scopeID else { return }
            resolvedDestination?.apply(workspaceID: workspaceID)
            self?.focusCreatedCloudWorkspace(workspaceID, manager: tabManager, revision: revision, windowID: request.windowID)
        }
    }

    /// The window a finished Cloud creation is allowed to navigate: the window
    /// that started the creation, and only while that window is still key.
    /// A creation that lands while the user is working in another window must
    /// not pull them away from it.
    ///
    /// This asks the window itself, the same way every other focus-gated path
    /// in the app does, rather than comparing against `NSApp.keyWindow`. The
    /// two agree in the running app, and the window-scoped question is the one
    /// this rule is actually about.
    func cloudWorkspaceCreationFocusWindow(windowID: UUID) -> NSWindow? {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowID }),
              let window = resolvedWindow(for: context),
              window.isKeyWindow else { return nil }
        return window
    }

    private func focusCreatedCloudWorkspace(_ workspaceID: UUID, manager: TabManager?, revision: UInt64, windowID: UUID) {
        guard let manager, manager.cloudWorkspaceSelection.revision == revision,
              tabManagerFor(windowId: windowID) === manager,
              cloudWorkspaceCreationFocusWindow(windowID: windowID) != nil,
              let workspace = manager.workspacesById[workspaceID] else { return }
        manager.selectWorkspace(workspace)
    }

    private func presentNoCloudMachineAvailableAlert(windowID: UUID) {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowID }),
              let window = resolvedWindow(for: context) else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "machines.empty.title", defaultValue: "No machines yet")
        alert.informativeText = String(
            localized: "machines.workspace.noMachines",
            defaultValue: "Create a machine with New Cloud Machine, then try again."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.beginSheetModal(for: window)
    }

    /// Places a machine's reservation immediately; later provisioning cannot undo user navigation.
    @discardableResult
    func performNewCloudMachineAction(
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
