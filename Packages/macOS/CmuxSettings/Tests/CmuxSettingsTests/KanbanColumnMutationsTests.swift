import Foundation
import Testing
@testable import CmuxSettings

/// Pure column-list behavior for the kanban board's Stage 3 mutation path
/// (`TabManager+Kanban` in the app target). Covers add/rename/recolor/
/// collapse/delete and the delete guard rules without constructing a
/// `TabManager` or `Workspace`.
@Suite("KanbanColumnMutations")
struct KanbanColumnMutationsTests {
    private func columns(
        _ entries: [(id: String, title: String, order: Int, isArchive: Bool)]
    ) -> [KanbanColumn] {
        entries.map { KanbanColumn(id: $0.id, title: $0.title, order: $0.order, isArchive: $0.isArchive) }
    }

    @Test func addingColumnAppendsAfterMaxOrder() {
        let result = KanbanColumnMutations.addingColumn(KanbanColumn.defaults, id: "new-1", title: "Review")
        #expect(result.last?.id == "new-1")
        #expect(result.last?.title == "Review")
        #expect(result.last?.order == (KanbanColumn.defaults.map(\.order).max() ?? -1) + 1)
        #expect(result.count == KanbanColumn.defaults.count + 1)
    }

    @Test func renamingColumnUpdatesOnlyTheMatchingColumn() {
        let result = KanbanColumnMutations.renamingColumn(KanbanColumn.defaults, id: "todo", title: "Backlog")
        #expect(result.first(where: { $0.id == "todo" })?.title == "Backlog")
        #expect(result.first(where: { $0.id == "done" })?.title == "Done")
    }

    @Test func renamingUnknownColumnIsANoOp() {
        let result = KanbanColumnMutations.renamingColumn(KanbanColumn.defaults, id: "nonexistent", title: "X")
        #expect(result == KanbanColumn.defaults)
    }

    @Test func settingColumnColorSetsAndClears() {
        let colored = KanbanColumnMutations.settingColumnColor(KanbanColumn.defaults, id: "todo", colorHex: "#FF0000")
        #expect(colored.first(where: { $0.id == "todo" })?.colorHex == "#FF0000")

        let cleared = KanbanColumnMutations.settingColumnColor(colored, id: "todo", colorHex: nil)
        #expect(cleared.first(where: { $0.id == "todo" })?.colorHex == nil)
    }

    @Test func settingColumnCollapsedTogglesOnlyThatColumn() {
        let result = KanbanColumnMutations.settingColumnCollapsed(KanbanColumn.defaults, id: "todo", collapsed: true)
        #expect(result.first(where: { $0.id == "todo" })?.isCollapsed == true)
        #expect(result.first(where: { $0.id == "in-progress" })?.isCollapsed == false)
    }

    @Test func deletingColumnReassignsToFirstRemainingNonArchiveColumnByDefault() {
        let deletion = KanbanColumnMutations.deletingColumn(KanbanColumn.defaults, id: "in-progress")
        #expect(deletion != nil)
        #expect(deletion?.reassignedToColumnId == "todo")
        #expect(deletion?.columns.contains(where: { $0.id == "in-progress" }) == false)
        #expect(deletion?.columns.count == KanbanColumn.defaults.count - 1)
    }

    @Test func deletingColumnHonorsExplicitReassignTo() {
        let deletion = KanbanColumnMutations.deletingColumn(KanbanColumn.defaults, id: "todo", reassignTo: "done")
        #expect(deletion?.reassignedToColumnId == "done")
    }

    @Test func deletingColumnIgnoresReassignToTargetingTheDeletedColumnItself() {
        // Asking to reassign to the column being deleted must fall back to the
        // default resolution, not point cards at a column that's about to vanish.
        let deletion = KanbanColumnMutations.deletingColumn(KanbanColumn.defaults, id: "todo", reassignTo: "todo")
        #expect(deletion?.reassignedToColumnId != "todo")
    }

    @Test func deletingArchiveColumnIsRefused() {
        let deletion = KanbanColumnMutations.deletingColumn(KanbanColumn.defaults, id: "archive")
        #expect(deletion == nil)
    }

    @Test func deletingTheLastNonArchiveColumnIsRefused() {
        let onlyOneRealColumn = columns([
            ("todo", "To Do", 0, false),
            ("archive", "Archive", 1, true),
        ])
        let deletion = KanbanColumnMutations.deletingColumn(onlyOneRealColumn, id: "todo")
        #expect(deletion == nil)
    }

    @Test func deletingWhenTwoRealColumnsRemainSucceeds() {
        let twoRealColumns = columns([
            ("todo", "To Do", 0, false),
            ("done", "Done", 1, false),
            ("archive", "Archive", 2, true),
        ])
        let deletion = KanbanColumnMutations.deletingColumn(twoRealColumns, id: "todo")
        #expect(deletion?.reassignedToColumnId == "done")
    }

    @Test func firstNonArchiveColumnIdIsLowestOrderNonArchiveColumn() {
        #expect(KanbanColumnMutations.firstNonArchiveColumnId(KanbanColumn.defaults) == "todo")
    }

    @Test func archiveColumnIdFindsTheArchiveFlaggedColumn() {
        #expect(KanbanColumnMutations.archiveColumnId(KanbanColumn.defaults) == "archive")
    }

    @Test func archiveColumnIdIsNilWhenNoneConfigured() {
        let noArchive = columns([("todo", "To Do", 0, false)])
        #expect(KanbanColumnMutations.archiveColumnId(noArchive) == nil)
    }
}
