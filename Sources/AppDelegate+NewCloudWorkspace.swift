import AppKit
import Foundation

/// The machine context captured for one New Workspace invocation. A Cloud tree
/// selection wins while that window's Machines panel owns focus; otherwise a
/// selected workspace's binding supplies the machine. Local workspaces remain
/// local even if another window or a hidden sidebar has an old Cloud selection.
struct NewWorkspaceMachineContext: Equatable {
    let machine: SurfaceMachineID

    init(
        selectedCloudMachineID: String?,
        selectedWorkspaceCloudMachineID: String?,
        machinesPanelOwnsFocus: Bool
    ) {
        if machinesPanelOwnsFocus,
           let selectedCloudMachineID = Self.normalized(selectedCloudMachineID) {
            machine = .cloud(selectedCloudMachineID)
        } else if let selectedWorkspaceCloudMachineID = Self.normalized(selectedWorkspaceCloudMachineID) {
            machine = .cloud(selectedWorkspaceCloudMachineID)
        } else {
            machine = .local
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

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
        if let context,
           case .cloud(let machineID) = newWorkspaceMachineContext(for: context).machine {
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
                return performNewCloudWorkspaceOnMachineAction(
                    machineID: machineID,
                    focus: context.tabManager.selectedTabId != nil,
                    windowID: context.windowId,
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
    /// focus coordinator decides later whether this selection is authoritative
    /// for Cmd+N, so a hidden/secondary window cannot redirect creation.
    func setSelectedCloudMachine(_ machine: SurfaceMachineID?, in tabManager: TabManager?) {
        guard let tabManager,
              let context = mainWindowContext(for: tabManager) else { return }
        context.selectedCloudMachineID = machine?.cloudMachineID
    }

    /// Resolves the target before any async Cloud operation starts.
    func newWorkspaceMachineContext(for context: MainWindowContext) -> NewWorkspaceMachineContext {
        NewWorkspaceMachineContext(
            selectedCloudMachineID: context.selectedCloudMachineID,
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
        debugSource: String = "newWorkspace.cloud"
    ) -> Bool {
        guard let coordinator = cloudWorkspaceCoordinator,
              let operationController = cloudWorkspaceOperationController,
              coordinator.isAvailable else { return false }
        let capturedMachineID = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedMachineID.isEmpty else { return false }
        return operationController.start(key: "new-cloud-workspace.machine:\(capturedMachineID)") {
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
        return operationController.start(key: "new-cloud-workspace.default") {
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
