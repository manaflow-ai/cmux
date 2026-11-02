import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// RECOVERABLE-BY-DEFAULT for workspace groups: Ungroup and Delete Group keep
/// every workspace and remember what the group was (name, color, collapse,
/// members, place). A person's Delete Group gets an undo toast in its
/// window; Undo and Cmd-Z (TOAST-UNDO-KEY) form the group again. A person's
/// Ungroup is only an undo step (Edit > Undo, Cmd-Z): it changes placement,
/// it deletes nothing, so it shows no toast (Lawrence 2026-10-18). Automation
/// (CLI, agents) gets neither. The daemon records the delete in closed history,
/// so Reopen Closed and History restore the group also after a restart; the
/// toast's Undo reopens that record (same group id) when the daemon serves
/// it, else forms the group again from the client's capture.
@MainActor
enum WorkspaceGroupUndo {
    static let toastID = "workspace-group-removed"

    /// Removes the targeted group, keeps its workspaces, offers the undo:
    /// a toast when `toast`, else a step on the window's undo stack only.
    static func remove(_ invocation: ActionInvocation, _ context: AppActionContext, message: (String) -> String,
                       toast: Bool = true) throws {
        let group = try context.group(invocation), sidebar = try context.sidebar(), prior = ToastUndoStep.latest
        let id = sidebar.model.groupID(personal: group.id.rawValue)
        let restore = SidebarGroupRestore.capture(id, in: sidebar.model.sections)
        sidebar.handle(.ungroup(id))
        // On the sidebar document the ungroup puts its own undo step now (the daemon's inverse keeps the pin, icon and
        // every member): the toast shares that step, and no client restore is added beside it.
        let onDoc = context.services.sidebarDoc.store?.activeRecords != nil, docStep = onDoc ? ToastUndoStep.latest.flatMap { $0 === prior ? nil : $0 } : nil
        guard invocation.origin == .user, let restore, let window = context.activeWindow?.window else { return }
        let name = group.name.isEmpty ? ConfirmationStrings.unnamedGroup : group.name
        let services = context.services, groupID = group.id.rawValue
        let undo: @MainActor () -> Void = { [weak sidebar] in
            if let entry = DaemonClosedHistory.groupEntry(groupID, in: services) {
                DaemonClosedHistory.reopen(entry, services: services)
            } else {
                sidebar?.handle(restore.intent(newID: .make()))
            }
        }
        guard toast else {
            if !onDoc { ToastUndoStep.attach(title: message(name), filling: nil, undoManager: window.undoManager, handle: nil, undo) }
            return
        }
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: message(name), action: .undo()), in: window)
        if let docStep { docStep.share(with: handle) } else if !onDoc { handle.onAction = undo }
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
