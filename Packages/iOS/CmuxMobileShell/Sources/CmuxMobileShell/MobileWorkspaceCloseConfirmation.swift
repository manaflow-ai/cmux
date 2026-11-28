internal import CmuxMobileSupport
public import CmuxMobileShellModel
import Foundation

/// The question closing a workspace row asks before it runs: an action
/// sheet with this title, message, and destructive button, plus Cancel.
///
/// Every close entrypoint (swipe, context menu, the workspace's own menu)
/// resolves it through ``MobileShellComposite/workspaceCloseConfirmation(id:)``,
/// so the rule lives in one place and the entrypoints only render it.
public struct MobileWorkspaceCloseConfirmation: Equatable, Sendable {
    public var title: String
    public var message: String
    public var actionTitle: String

    public init(title: String, message: String, actionTitle: String) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
    }

    /// Closing a paired Mac's workspace.
    public static var macWorkspace: Self {
        Self(
            title: L10n.string("mobile.workspace.delete.confirmTitle", defaultValue: "Delete Workspace?"),
            message: L10n.string("mobile.workspace.delete.confirmMessage", defaultValue: "This will close the workspace on your Mac."),
            actionTitle: L10n.string("mobile.workspace.delete.confirmAction", defaultValue: "Delete")
        )
    }

    /// The rule for an SSH workspace row, by kind. `nil` means close in one
    /// tap.
    ///
    /// The discriminator is persistence, not who created the row: tmux
    /// sessions and cmux-tui workspaces outlive the phone (they keep running
    /// when it disconnects, other devices can be attached, and a job started
    /// from the phone keeps running there), so ending one destroys state the
    /// phone does not own and cannot undo, which always asks (HIG, Alerts:
    /// confirm uncommon destructive actions that can't be undone). A shell
    /// exists only for this phone's channel and ends when the phone
    /// disconnects anyway, so closing it is as routine as closing a tab.
    /// A `nil` kind is an id the runtime cannot parse, whose close is a
    /// no-op, so it needs no question either.
    public static func ssh(
        kind: MobileSSHWorkspaceKind?,
        workspaceName: String,
        hostName: String
    ) -> Self? {
        let title = L10n.string(
            "mobile.ssh.close.confirmTitle",
            defaultValue: "End “\(workspaceName)” on \(hostName)?"
        )
        switch kind {
        case .tmux:
            return Self(
                title: title,
                message: L10n.string(
                    "mobile.ssh.close.tmux.confirmMessage",
                    defaultValue: "This closes the tmux session and stops everything running in it, including anything open on other devices."
                ),
                actionTitle: L10n.string("mobile.ssh.close.tmux.confirmAction", defaultValue: "End Session")
            )
        case .cmuxTUI:
            return Self(
                title: title,
                message: L10n.string(
                    "mobile.ssh.close.cmuxTUI.confirmMessage",
                    defaultValue: "This closes the workspace and its terminals and stops everything running in them, including anything open on other devices."
                ),
                actionTitle: L10n.string("mobile.ssh.close.cmuxTUI.confirmAction", defaultValue: "Close Workspace")
            )
        case .shell, nil:
            return nil
        }
    }
}

@MainActor
extension MobileShellComposite {
    /// What closing workspace row `id` asks first; `nil` closes at once.
    /// Mac rows keep the Mac question; SSH rows follow
    /// ``MobileWorkspaceCloseConfirmation/ssh(kind:workspaceName:hostName:)``.
    public func workspaceCloseConfirmation(id: MobileWorkspacePreview.ID) -> MobileWorkspaceCloseConfirmation? {
        guard sshOwnsWorkspaceRow(id) else { return .macWorkspace }
        let row = workspaces.first { $0.id == id }
        let hostName = row?.macDeviceID.flatMap(sshHostID(computerDeviceID:))
            .flatMap { sshComputers.host(id: $0)?.name }
            ?? row?.macDisplayName
            ?? ""
        return .ssh(
            kind: sshWorkspaceKind(workspaceID: id),
            workspaceName: row?.name ?? "",
            hostName: hostName
        )
    }
}
