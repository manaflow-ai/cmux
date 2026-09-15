import AppKit
import Foundation

enum NewWorkspaceMachineSelection: Equatable {
    case none
    case local
    case cloud(String)
    case pending
}

/// The machine target captured for one New Workspace invocation.
struct NewWorkspaceMachineContext: Equatable {
    enum Target: Equatable {
        case local
        case cloud(String)
        case unavailable
    }

    let target: Target

    init(
        selection: NewWorkspaceMachineSelection,
        selectedWorkspaceCloudMachineID: String?,
        machinesPanelOwnsFocus: Bool
    ) {
        if machinesPanelOwnsFocus {
            switch selection {
            case .cloud(let id) where !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                target = .cloud(id.trimmingCharacters(in: .whitespacesAndNewlines))
            case .local:
                target = .local
            case .pending:
                target = .unavailable
            case .none, .cloud:
                target = Self.workspaceTarget(selectedWorkspaceCloudMachineID)
            }
        } else {
            target = Self.workspaceTarget(selectedWorkspaceCloudMachineID)
        }
    }

    private static func workspaceTarget(_ value: String?) -> Target {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? .cloud(value!) : .local
    }
}

// MARK: - Cloud creation actions

extension AppDelegate {
    /// Records the Machines tree selection for the owning window. The active
    /// focus coordinator decides later whether this selection is authoritative.
    func setNewWorkspaceMachineSelection(_ selection: NewWorkspaceMachineSelection, in tabManager: TabManager?) {
        guard let tabManager,
              let context = mainWindowContext(for: tabManager) else { return }
        context.newWorkspaceMachineSelection = selection
    }

    func newWorkspaceMachineContext(for context: MainWindowContext) -> NewWorkspaceMachineContext {
        NewWorkspaceMachineContext(
            selection: context.newWorkspaceMachineSelection,
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
        return operationController.start(key: "new-cloud-workspace.machine:\(capturedMachineID)") {
            guard let workspaceID = try await coordinator.createOnMachine(
                machineID: capturedMachineID,
                focus: focus,
                windowID: windowID
            ),
                  !Task.isCancelled,
                  coordinator.isAvailable else { return }
            destination?.apply(workspaceID: workspaceID)
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
