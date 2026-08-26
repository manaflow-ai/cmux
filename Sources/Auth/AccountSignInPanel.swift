import Bonsplit
import CmuxWorkspaces
import Foundation

/// Transient workspace surface that owns the in-pane Stack sign-in state.
@MainActor
final class AccountSignInPanel: Panel {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .accountSignIn
    let model: AccountSignInModel

    var displayTitle: String {
        String(localized: "account.signIn.workspace.title", defaultValue: "Sign In")
    }

    var displayIcon: String? { "person.crop.circle" }

    init(flow: any AccountSignInFlow) {
        model = AccountSignInModel(flow: flow)
    }

    func focus() {}
    func unfocus() {}
    func close() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) { _ = reason }
}

extension Workspace {
    @discardableResult
    func newAccountSignInSurface(
        inPane paneID: PaneID,
        flow: any AccountSignInFlow,
        focus: Bool = true
    ) -> AccountSignInPanel? {
        let panel = AccountSignInPanel(flow: flow)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let tabID = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.accountSignIn.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneID
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }

        bindSurface(tabID, toPanelId: panel.id)
        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneID,
            kind: SurfaceKind.accountSignIn.rawValue,
            origin: "account_sign_in_workspace",
            focused: focus
        )
        if focus {
            bonsplitController.focusPane(paneID)
            bonsplitController.selectTab(tabID)
            applyTabSelection(tabId: tabID, inPane: paneID)
        }
        return panel
    }
}
