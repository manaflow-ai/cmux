public import AppKit
import CmuxNextDesign

/// The toast a person's Cmd-W on a workspace's last tab shows when it closes the workspace (audit C, Lawrence
/// 2026-10-28): "Workspace closed" with Undo for 5 s; Undo runs Reopen Closed (Cmd-Shift-T), which brings the
/// workspace back with its layout, tabs and terminals.
@MainActor
public enum WorkspaceClosedToast {
    /// The toast's id in `CmuxToastCenter`.
    public static let id = "workspace-closed"

    /// Shows the toast in `window`; `shortcut`: Reopen Closed's key, shown in the Undo button ("Undo (⇧⌘T)").
    public static func show(in window: NSWindow, shortcut: String?, undo: @escaping @MainActor () -> Void) {
        let title = shortcut.map(Strings.undoWithShortcut) ?? CmuxToastStrings.undo
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: id, message: Strings.workspaceClosed, action: .undo(title), duration: .seconds(5)),
                                                 in: window)
        handle.onAction = undo
    }
}
