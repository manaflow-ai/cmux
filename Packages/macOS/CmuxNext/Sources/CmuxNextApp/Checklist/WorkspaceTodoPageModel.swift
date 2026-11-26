import CmuxNextActions
import CmuxNextDaemon
import Foundation
import Observation

/// The Todo page's model: one workspace's checklist, read live from the store, and the page's
/// edits, each run as its checklist action (``WorkspaceChecklistHandlers``) so the page edits the
/// checklist exactly as the palette, the menus and the CLI do.
@MainActor @Observable
final class WorkspaceTodoPageModel {
    /// The workspace whose checklist the page shows (`WorkspaceModel.id`).
    var workspaceID: String
    /// The text of the item being added.
    var draft = ""
    /// The item whose text is being edited, if any.
    var editing: String?

    private let workspace: @MainActor (String) -> WorkspaceModel?
    private let perform: @MainActor (ActionID, ActionInvocation) -> Void

    /// - Parameters:
    ///   - workspaceID: The workspace to show.
    ///   - workspace: Looks a workspace up by id (the store; tracked, so the page follows it).
    ///   - perform: Runs an action (the app's registry).
    init(workspaceID: String, workspace: @escaping @MainActor (String) -> WorkspaceModel?,
         perform: @escaping @MainActor (ActionID, ActionInvocation) -> Void) {
        self.workspaceID = workspaceID
        self.workspace = workspace
        self.perform = perform
    }

    /// The workspace, nil once it closed.
    var shown: WorkspaceModel? { workspace(workspaceID) }
    /// The checklist in list order.
    var items: [WorkspaceChecklistItem] { shown?.checklist ?? [] }

    func add(_ text: String) { run("palette.addWorkspaceChecklistItem", ["text": .string(text)]) }
    func toggle(_ item: String) { run("toggleChecklistItemComplete", ["item": .string(item)]) }
    func complete(_ item: String) { run("checklistCompleteItem", ["item": .string(item)]) }

    /// In progress runs Mark In Progress; done runs Complete; to do runs Toggle on a done item.
    func setState(_ item: String, _ state: WorkspaceChecklistItem.State) {
        switch state {
        case .inProgress: run("checklistMarkInProgress", ["item": .string(item)])
        case .done: complete(item)
        case .todo:
            if items.first(where: { $0.id == item })?.state == .done { toggle(item) }
        }
    }

    func edit(_ item: String, text: String) { run("checklistEditItem", ["item": .string(item), "text": .string(text)]) }
    func remove(_ item: String) { run("checklistRemoveItem", ["item": .string(item)]) }
    /// Asks for images with the cmux picker and attaches them.
    func attachImages(_ item: String) { run("checklistAttachImages", ["item": .string(item)]) }

    /// Adds the draft, then clears it.
    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        add(text)
        draft = ""
    }

    private func run(_ id: ActionID, _ arguments: [String: ActionValue]) {
        perform(id, ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspaceID), arguments: arguments))
    }
}
