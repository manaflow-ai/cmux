import AppKit
import Foundation

// MARK: - New Cloud Workspace (Cmd+Y)

extension AppDelegate {
    /// Creates a workspace on the persisted default machine. This is the fast
    /// path behind Cmd+Y; it never presents a sheet or provisions a machine.
    @discardableResult
    func performNewCloudWorkspaceOnDefaultMachineAction(
        preferredWindow: NSWindow? = nil,
        debugSource: String = "newCloudWorkspace"
    ) -> Bool {
        guard CloudMachinesFeature.isEnabled,
              Self.newCloudWorkspaceAuthStateOverride?.allowsAuthenticatedOperation
                ?? (auth?.accountFlow.isAuthenticated == true) else { return false }

        let snapshots = SurfaceCatalog.shared.snapshot.machines.compactMap { info -> MachineSnapshot? in
            guard case .cloud(let id) = info.id else { return nil }
            return MachineSnapshot(
                id: id,
                provider: "cloud",
                image: info.image ?? "",
                isDesktop: info.hasDesktop,
                activity: MachineSnapshot.Activity.ready,
                createdAt: nil,
                label: info.name
            )
        }
        guard let selected = DefaultCloudMachineStore.shared.resolveMachineID(from: snapshots),
              let provider = SurfaceCatalog.shared.provider(for: .cloud(selected)) else { return false }
        let catalog = SurfaceCatalog.shared
        let context = preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        let focus = context?.tabManager.selectedTabId != nil
        Task { @MainActor in
            do {
                _ = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: .cloud(selected), provider: provider, catalog: catalog,
                    name: nil, focus: focus
                )
            } catch {
#if DEBUG
                cmuxDebugLog("newCloudWorkspace.failed source=\(debugSource) error=\(error)")
#endif
            }
        }
        return true
    }

    /// The one path every "New Cloud Workspace" entrypoint goes through:
    /// the `newCloudWorkspace` shortcut, File > New Cloud Workspace, the
    /// plus-menu row, the `cmux.newCloudWorkspace` config action, and the
    /// command palette's "New Cloud Machine…". Gates on the Cloud Machines
    /// feature and on sign-in, then opens the New Machine sheet; Create
    /// launches `cmux vm new …`, which provisions a machine and attaches it
    /// as a new workspace.
    ///
    /// Returns false when the feature is off or the person is signed out, so
    /// callers can leave their key equivalent genuinely inert.
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
        let authState = Self.newCloudWorkspaceAuthStateOverride ?? CloudVMPanelAuthState.resolve(
            isAuthenticated: auth?.accountFlow.isAuthenticated == true,
            isWorkingOnAuth: auth?.accountFlow.isWorkingOnAuth == true
        )
        guard authState.allowsAuthenticatedOperation else {
#if DEBUG
            cmuxDebugLog("newCloudWorkspace.blocked_signed_out source=\(debugSource)")
#endif
            return false
        }
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
        newCloudWorkspaceSheetPresenter.presentNewMachineFetchingPlan(preferredWindow: hostWindow)
        return true
    }

    /// Test seam: the sheet presenter the shared action hands off to.
    var newCloudWorkspaceSheetPresenter: NewMachineSheetPresenting {
        Self.newCloudWorkspaceSheetPresenterOverride ?? NewMachineSheetPresenter.shared
    }

    /// Tests install a recording presenter here; nil means the real sheet.
    @MainActor
    static var newCloudWorkspaceSheetPresenterOverride: NewMachineSheetPresenting?

    /// Tests pin the sign-in state here; nil reads the live account flow.
    @MainActor
    static var newCloudWorkspaceAuthStateOverride: CloudVMPanelAuthState?
}

/// The slice of `NewMachineSheetPresenter` the New Cloud Workspace action
/// depends on, so tests can observe the handoff without a window.
@MainActor
protocol NewMachineSheetPresenting: AnyObject {
    func presentNewMachineFetchingPlan(preferredWindow: NSWindow?)
}

extension NewMachineSheetPresenter: NewMachineSheetPresenting {}
