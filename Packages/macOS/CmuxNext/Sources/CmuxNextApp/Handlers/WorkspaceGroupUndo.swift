import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// RECOVERABLE-BY-DEFAULT for workspace groups: Ungroup and Delete Group keep
/// every workspace and remember what the group was (name, color, collapse,
/// members, place). A person's gesture gets an undo toast in its window;
/// Undo and Cmd-Z (TOAST-UNDO-KEY) form the group again. Automation (CLI,
/// agents) gets no toast. The daemon records the delete in closed history,
/// so Reopen Closed and History restore the group also after a restart; the
/// toast's Undo reopens that record (same group id) when the daemon serves
/// it, else forms the group again from the client's capture.
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
        let services = context.services, groupID = group.id.rawValue
        handle.onAction = { [weak sidebar] in
            if let entry = DaemonClosedHistory.groupEntry(groupID, in: services) {
                DaemonClosedHistory.reopen(entry, services: services)
            } else {
                sidebar?.handle(restore.intent(newID: .make()))
            }
        }
    }

    /// The title History gives a deleted group's closed-history item.
    static func historyTitle(_ name: String) -> String {
        let name = name.isEmpty ? ConfirmationStrings.unnamedGroup : name
        return String(format: String(localized: "workspaceGroup.closedHistoryTitle", defaultValue: "Group “%@”", table: "Handlers", bundle: .module), name)
    }

    static func ungroupedToast(_ name: String) -> String {
        String(format: String(localized: "workspaceGroup.ungroupedToast", defaultValue: "Ungrouped “%@”", table: "Handlers", bundle: .module), name)
    }

    static func deletedToast(_ name: String) -> String {
        String(format: String(localized: "workspaceGroup.deletedToast", defaultValue: "Group “%@” deleted", table: "Handlers", bundle: .module), name)
    }
}
