import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// RECOVERABLE-BY-DEFAULT for workspace groups: Ungroup and Delete Group keep
/// every workspace and remember what the group was (name, color, collapse,
/// members, place). A person's gesture gets an undo toast in its window;
/// Undo and Cmd-Z (TOAST-UNDO-KEY) form the group again. Automation (CLI,
/// agents) gets no toast. The daemon-side closed-history record (Cmd-Shift-T
/// after a restart) needs a store change and waits for the WINDOW.
@MainActor
enum WorkspaceGroupUndo {
    static let toastID = "workspace-group-removed"

    /// Removes the targeted group, keeps its workspaces, offers the undo.
    static func remove(_ invocation: ActionInvocation, _ context: AppActionContext, message: (String) -> String) throws {
        let group = try context.group(invocation)
        let sidebar = try context.sidebar()
        let id = CmuxNextSidebar.GroupID(group.id.rawValue)
        let restore = SidebarGroupRestore.capture(id, in: sidebar.model.sections)
        sidebar.handle(.ungroup(id))
        guard invocation.origin == .user, let restore, let window = context.activeWindow?.window else { return }
        let name = group.name.isEmpty ? ConfirmationStrings.unnamedGroup : group.name
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: message(name), action: .undo()), in: window)
        handle.onAction = { [weak sidebar] in
            sidebar?.handle(restore.intent(newID: .make()))
        }
    }

    static func ungroupedToast(_ name: String) -> String {
        String(format: String(localized: "workspaceGroup.ungroupedToast", defaultValue: "Ungrouped “%@”", table: "Handlers", bundle: .module), name)
    }

    static func deletedToast(_ name: String) -> String {
        String(format: String(localized: "workspaceGroup.deletedToast", defaultValue: "Group “%@” deleted", table: "Handlers", bundle: .module), name)
    }
}
