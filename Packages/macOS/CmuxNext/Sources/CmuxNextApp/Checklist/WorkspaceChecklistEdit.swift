import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import CmuxNextTasks

/// The one change a checklist action makes (`workspace-checklist-v1`). Every entrypoint (palette,
/// workspace menu, Cmd-Return, the Todo page, `cmux action run`) reads its action and arguments
/// through ``make(for:invocation:items:)``, so all of them edit the checklist the same way.
struct WorkspaceChecklistEdit: Equatable {
    /// The daemon operation.
    enum Operation: Equatable { case add, update, remove }

    var operation: Operation
    /// The item to change or remove; nil for an add.
    var item: String?
    /// The new text (add, edit).
    var text: String?
    /// The new state.
    var state: WorkspaceChecklistItem.State?
    /// The item's whole new attachment list.
    var attachments: [WorkspaceChecklistAttachment]?

    /// `workspace_checklist.add`: a new item at the end.
    static func add(text: String) -> Self { Self(operation: .add, text: text) }
    /// `workspace_checklist.update` of the item's state.
    static func update(item: String, state: WorkspaceChecklistItem.State) -> Self { Self(operation: .update, item: item, state: state) }
    /// `workspace_checklist.update` of the item's text.
    static func update(item: String, text: String) -> Self { Self(operation: .update, item: item, text: text) }
    /// `workspace_checklist.update` of the item's whole attachment list.
    static func update(item: String, attachments: [WorkspaceChecklistAttachment]) -> Self {
        Self(operation: .update, item: item, attachments: attachments)
    }
    /// `workspace_checklist.remove`.
    static func remove(item: String) -> Self { Self(operation: .remove, item: item) }

    /// The edit `id` makes with `invocation`'s arguments on a checklist of `items`. The `item`
    /// argument names the item; without it the action acts on the current item (the first in
    /// progress, else the first to do). Throws a refusal for empty text or an unknown item.
    static func make(for id: ActionID, invocation: ActionInvocation, items: [WorkspaceChecklistItem]) throws -> Self {
        switch id {
        case "palette.addWorkspaceChecklistItem":
            return .add(text: try text(invocation))
        case "toggleChecklistItemComplete":
            let item = try target(invocation, items: items)
            return .update(item: item.id, state: item.state.togglingComplete)
        case "checklistCompleteItem":
            return .update(item: try target(invocation, items: items).id, state: .done)
        case "checklistMarkInProgress":
            return .update(item: try target(invocation, items: items).id, state: .inProgress)
        case "checklistEditItem":
            let item = try target(invocation, items: items)
            return .update(item: item.id, text: try text(invocation))
        case "checklistRemoveItem":
            return .remove(item: try target(invocation, items: items).id)
        case "checklistAttachImages":
            let item = try target(invocation, items: items)
            guard let path = invocation["path"]?.stringValue, !path.isEmpty else {
                throw ActionFailure.invalidTarget(WorkspaceChecklistStrings.noImage)
            }
            return attaching([path], to: item)
        default:
            throw ActionFailure.invalidTarget(WorkspaceChecklistStrings.noItem)
        }
    }

    /// The item an action acts on: the `item` argument, else the current item.
    static func target(_ invocation: ActionInvocation, items: [WorkspaceChecklistItem]) throws -> WorkspaceChecklistItem {
        if let id = invocation["item"]?.stringValue, !id.isEmpty {
            guard let item = items.first(where: { $0.id == id }) else {
                throw ActionFailure.invalidTarget(WorkspaceChecklistStrings.unknownItem)
            }
            return item
        }
        guard let item = items.first(where: { $0.state == .inProgress }) ?? items.first(where: { $0.state == .todo }) else {
            throw ActionFailure.invalidTarget(WorkspaceChecklistStrings.noItem)
        }
        return item
    }

    /// The item's attachments with `paths` after them, as one update.
    static func attaching(_ paths: [String], to item: WorkspaceChecklistItem) -> Self {
        .update(item: item.id, attachments: item.attachments + paths.map { WorkspaceChecklistAttachment(path: $0) })
    }

    private static func text(_ invocation: ActionInvocation) throws -> String {
        let text = (invocation["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ActionFailure.invalidTarget(WorkspaceChecklistStrings.emptyText) }
        return text
    }
}
