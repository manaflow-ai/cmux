import AppKit
import Foundation

// MARK: - New Cloud Workspace (Cmd+Y)

extension AppDelegate {
    /// The one path every "New Cloud Workspace" entrypoint goes through:
    /// the `newCloudWorkspace` shortcut, File > New Cloud Workspace, the
    /// plus-menu row, the `cmux.newCloudWorkspace` config action, and the
    /// command palette's "New Cloud Machine…". Gates on the Cloud Machines
    /// feature and on sign-in, then opens the New Machine sheet; Create
    /// launches `cmux vm new …`, which provisions a machine and attaches it
    /// as a new workspace.
    ///
    /// Returns false when the feature is off or the person is signed out
    /// (the sign-in workspace opens instead), so callers can beep or skip
    /// `onExecuted`.
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
            NSSound.beep()
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
            _ = performAccountSignInWorkspaceAction(
                preferredWindow: preferredWindow,
                debugSource: "\(debugSource).auth"
            )
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
