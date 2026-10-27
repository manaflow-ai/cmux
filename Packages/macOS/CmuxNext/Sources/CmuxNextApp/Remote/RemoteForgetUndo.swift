import AppKit
import CmuxNextDesign

/// Forget Machine from a person's gesture (RECOVERABLE-BY-DEFAULT, Lawrence
/// 2026-10-07: no question): the machine disconnects and leaves the sidebar
/// at once, and "Forgot <machine>" with Undo shows in the window. Undo (and
/// Cmd-Z, TOAST-UNDO-KEY) brings it back as it was saved. The saved list and
/// the home session's record are written only when the toast ends another
/// way (time out, close, a newer toast, its window closing). A quit while
/// the toast shows writes nothing, so the machine is back at the next
/// launch: a lost Forget, never a lost machine. Automation forgets at once.
@MainActor
enum RemoteForgetUndo {
    static let toastID = "remote-forgot"

    static func forget(_ session: SSHMachineSession, ssh: SSHService, in window: NSWindow) {
        let pending = ssh.hide(session)
        let handle = CmuxToastCenter.shared.show(
            CmuxToast(id: toastID, message: RemoteStrings.forgotToast(pending.label), action: .undo()), in: window)
        handle.onAction = { [weak ssh] in ssh?.unhide(pending) }
        handle.onDismiss = { [weak ssh] reason in
            guard reason != .action, let ssh else { return }
            ssh.commitForget(pending)
        }
    }
}
