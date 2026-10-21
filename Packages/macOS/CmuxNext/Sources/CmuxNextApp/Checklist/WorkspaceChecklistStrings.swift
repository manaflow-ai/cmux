import Foundation

/// The Todo page and the checklist refusals (Resources/WorkspaceChecklist.xcstrings).
nonisolated enum WorkspaceChecklistStrings {
    static var pageTitle: String { text("workspaceChecklist.page.title", "Todo") }
    static var addPlaceholder: String { text("workspaceChecklist.page.addPlaceholder", "Add an item") }
    static var empty: String { text("workspaceChecklist.page.empty", "No items yet. Add one above, or run cmux workspace checklist add.") }
    static var noWorkspace: String { text("workspaceChecklist.page.noWorkspace", "This workspace is closed.") }
    static var markInProgress: String { text("workspaceChecklist.page.markInProgress", "Mark In Progress") }
    static var markTodo: String { text("workspaceChecklist.page.markTodo", "Mark To Do") }
    static var complete: String { text("workspaceChecklist.page.complete", "Complete") }
    static var edit: String { text("workspaceChecklist.page.edit", "Edit") }
    static var attachImages: String { text("workspaceChecklist.page.attachImages", "Attach Images…") }
    static var remove: String { text("workspaceChecklist.page.remove", "Remove") }
    static var toggle: String { text("workspaceChecklist.page.toggle", "Toggle Complete") }
    static var emptyText: String { text("workspaceChecklist.refusal.emptyText", "the checklist item text is empty") }
    static var unknownItem: String { text("workspaceChecklist.refusal.unknownItem", "the workspace checklist has no such item") }
    static var noItem: String { text("workspaceChecklist.refusal.noItem", "the workspace checklist has no item to do") }
    static var noImage: String { text("workspaceChecklist.refusal.noImage", "a path argument naming an image file is required") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "WorkspaceChecklist", bundle: .module)
    }
}
