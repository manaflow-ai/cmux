package import Foundation

/// The Todo page and the checklist refusals (Resources/WorkspaceChecklist.xcstrings).
package nonisolated struct WorkspaceChecklistStrings {
    package nonisolated init() {}
    /// The bundle that holds `Resources/WorkspaceChecklist.xcstrings` (this module's), for tests.
    package static var bundle: Bundle { .module }
    package static var pageTitle: String { text("workspaceChecklist.page.title", "Todo") }
    package static var addPlaceholder: String { text("workspaceChecklist.page.addPlaceholder", "Add an item") }
    package static var empty: String { text("workspaceChecklist.page.empty", "No items yet. Add one above, or run cmux workspace checklist add.") }
    package static var noWorkspace: String { text("workspaceChecklist.page.noWorkspace", "This workspace is closed.") }
    package static var markInProgress: String { text("workspaceChecklist.page.markInProgress", "Mark In Progress") }
    package static var markTodo: String { text("workspaceChecklist.page.markTodo", "Mark To Do") }
    package static var complete: String { text("workspaceChecklist.page.complete", "Complete") }
    package static var edit: String { text("workspaceChecklist.page.edit", "Edit") }
    package static var attachImages: String { text("workspaceChecklist.page.attachImages", "Attach Images…") }
    package static var remove: String { text("workspaceChecklist.page.remove", "Remove") }
    package static var toggle: String { text("workspaceChecklist.page.toggle", "Toggle Complete") }
    package static var emptyText: String { text("workspaceChecklist.refusal.emptyText", "the checklist item text is empty") }
    package static var unknownItem: String { text("workspaceChecklist.refusal.unknownItem", "the workspace checklist has no such item") }
    package static var noItem: String { text("workspaceChecklist.refusal.noItem", "the workspace checklist has no item to do") }
    package static var noImage: String { text("workspaceChecklist.refusal.noImage", "a path argument naming an image file is required") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "WorkspaceChecklist", bundle: .module)
    }
}
