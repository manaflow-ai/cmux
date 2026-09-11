import AppKit
import Foundation
import os

// MARK: - New Cloud Workspace (Cmd+Y)

extension AppDelegate {
    /// Creates a workspace on the persisted default machine. This is the fast
    /// path behind Cmd+Y; it never presents a sheet or provisions a machine.
    @discardableResult
    func performNewCloudWorkspaceOnDefaultMachineAction(
        preferredWindow: NSWindow? = nil,
        debugSource: String = "newCloudWorkspace",
        onCreated: ((UUID) -> Void)? = nil
    ) -> Bool {
        guard let coordinator = cloudWorkspaceCoordinator, coordinator.isAvailable else { return false }
        let context = preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        let focus = context?.tabManager.selectedTabId != nil
        let operationID = UUID()
        cloudWorkspaceTasks[operationID] = Task { @MainActor [weak self] in
            defer { self?.cloudWorkspaceTasks.removeValue(forKey: operationID) }
            do {
                let workspaceID = try await coordinator.createOnDefaultMachine(focus: focus)
                if !Task.isCancelled, coordinator.isAvailable, let workspaceID {
                    onCreated?(workspaceID)
                }
            } catch is CancellationError {
                // Access ending cancels the app-owned operation.
            } catch {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app", category: "CloudWorkspace")
                    .error("Cloud workspace creation failed: \(String(describing: error), privacy: .private)")
            }
        }
        return true
    }

    /// Opens the New Machine sheet for Cmd+Shift+Y, menus, and configured actions.
    /// Returns false when Cloud Machines or the authenticated account is unavailable.
    @discardableResult
    func performNewCloudWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "newCloudWorkspace"
    ) -> Bool {
        guard CloudMachinesFeature.isEnabled else {
#if DEBUG
            cmuxDebugLog("newCloudWorkspace.blocked_feature_disabled source=\(debugSource)")
#endif
            return false
        }
        guard cloudWorkspaceCoordinator?.isAvailable == true,
              let newMachineSheetPresenter else { return false }
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? preferredWindow.flatMap { contextForMainWindow($0) }
            ?? event.flatMap { mainWindowContext(forShortcutEvent: $0, debugSource: debugSource) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        let hostWindow = context.flatMap { resolvedWindow(for: $0) }
            ?? preferredWindow
            ?? event?.window
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow
#if DEBUG
        cmuxDebugLog("newCloudWorkspace.present_sheet source=\(debugSource)")
#endif
        newMachineSheetPresenter.presentNewMachineFetchingPlan(preferredWindow: hostWindow)
        return true
    }

    /// Cancels menu-launched operations when Cloud access ends or the app terminates.
    func cancelCloudWorkspaceOperations() {
        for task in cloudWorkspaceTasks.values { task.cancel() }
        cloudWorkspaceTasks.removeAll()
    }
}
