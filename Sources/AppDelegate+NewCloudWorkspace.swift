import AppKit
import CmuxCloud
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
              coordinator.isAvailable, let scopeID = coordinator.scopeIdentifier else {
            return performNewCloudMachineAction(
                tabManager: preferredTabManager,
                preferredWindow: preferredWindow,
                debugSource: "\(debugSource).fallback"
            )
        }
        guard let context = preferredTabManager.flatMap({ mainWindowContext(for: $0) })
            ?? preferredWindow.flatMap({ contextForMainWindow($0) })
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource) else {
            return performNewCloudMachineAction(
                tabManager: preferredTabManager,
                preferredWindow: preferredWindow,
                debugSource: "\(debugSource).fallback"
            )
        }
        let manager = context.tabManager
        manager.recordCloudWorkspaceSelection()
        let selection = manager.rememberedCloudWorkspaceSelection
        let revision = manager.cloudWorkspaceSelection.revision
        let windowID = context.windowId
        return operationController.start(key: "new-cloud-workspace.resolved.\(windowID.uuidString)") { [weak self, weak manager] in
            let fallbackToNewMachine: @MainActor () -> Void = { [weak self, weak manager] in
                guard let self, !Task.isCancelled else { return }
                let fallbackWindow = self.mainWindowContexts.values
                    .first(where: { $0.windowId == windowID })
                    .flatMap { self.resolvedWindow(for: $0) }
                _ = self.performNewCloudMachineAction(
                    tabManager: manager,
                    preferredWindow: fallbackWindow,
                    debugSource: "\(debugSource).fallback"
                )
            }
            let reveals = SurfaceCatalog.shared.cloudWorkspaceCreationCoordinator.reveals
            let token = manager.map { reveals.begin(in: $0) }
            var accessBecameUnavailable = false
            do {
                try await reveals.revealing(token) {
                    guard let workspaceID = try await coordinator.createOnResolvedMachine(
                        selection: selection, windowID: windowID, scopeID: scopeID, selectionRevision: revision
                    ) else {
                        accessBecameUnavailable = !coordinator.isAvailable
                            || coordinator.scopeIdentifier != scopeID
                        return nil
                    }
                    // A successful create is already committed on the Cloud
                    // machine. Availability can change while the result is
                    // being projected into the sidebar; that must not turn a
                    // completed workspace into a spurious New Machine flow.
                    guard !Task.isCancelled else { return nil }
                    destination?.apply(workspaceID: workspaceID)
                    return self?.focusCreatedCloudWorkspace(workspaceID, manager: manager, revision: revision, windowID: windowID)
                }
                if accessBecameUnavailable {
                    fallbackToNewMachine()
                }
            } catch CloudWorkspaceCreationError.noMachines {
                guard !Task.isCancelled else { return }
                fallbackToNewMachine()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Creation failures are reported by the operation controller.
                // New Machine is reserved for a missing or unusable Cloud
                // context, never for an arbitrary provider error.
                throw error
            }
        }
    }

    /// Creates on the machine explicitly selected by a context-following New Workspace action.
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
        let revision = tabManager.cloudWorkspaceSelection.revision
        let request = CloudWorkspaceCreationRequest(
            machineID: vmID, scopeID: scopeID, windowID: context.windowId, selectionRevision: revision
        )
        return operationController.start(key: "new-cloud-workspace.\(vmID).\(context.windowId.uuidString)") { [weak self, weak tabManager] in
            let reveals = SurfaceCatalog.shared.cloudWorkspaceCreationCoordinator.reveals
            let token = tabManager.map { reveals.begin(in: $0) }
            try await reveals.revealing(token) {
                guard let workspaceID = try await coordinator.createOnMachine(request),
                      !Task.isCancelled, coordinator.isAvailable, coordinator.scopeIdentifier == scopeID else { return nil }
                resolvedDestination?.apply(workspaceID: workspaceID)
                return self?.focusCreatedCloudWorkspace(workspaceID, manager: tabManager, revision: revision, windowID: request.windowID)
            }
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

    /// Returns the workspace it selected, which the window's Cloud tree then reveals.
    private func focusCreatedCloudWorkspace(_ workspaceID: UUID, manager: TabManager?, revision: UInt64, windowID: UUID) -> Workspace? {
        guard let manager,
              tabManagerFor(windowId: windowID) === manager,
              cloudWorkspaceCreationFocusWindow(windowID: windowID) != nil,
              let workspace = manager.workspacesById[workspaceID] else { return nil }

        // Admission selects the loading workspace before provider lookup. That
        // intentional selection advances the navigation fence once; accept it
        // only when it is exactly that admission revision. A later away/back
        // navigation leaves the same workspace selected but has a newer fence,
        // so it still withdraws the reveal instead of stealing focus.
        if manager.selectedTabId == workspaceID {
            guard manager.cloudWorkspaceSelection.revision == revision &+ 1 else { return nil }
            return workspace
        }
        guard manager.cloudWorkspaceSelection.revision == revision else { return nil }
        manager.selectWorkspace(workspace)
        return manager.selectedTabId == workspace.id ? workspace : nil
    }

    /// Places a machine's reservation immediately; later provisioning cannot undo user navigation.
    @discardableResult
    func performNewCloudMachineAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "newCloudMachine",
        destination: CloudWorkspaceGroupDestination? = nil
    ) -> Bool {
        if CloudMachinesFeature.isAvailable, !CloudMachinesFeature.isEnabled {
            Self.presentPreferencesWindow(navigationTarget: .cloudMachines)
            return true
        }
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
