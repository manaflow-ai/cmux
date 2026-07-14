import CmuxSettings
import CmuxSettingsUI
import Foundation

/// The one shared mutation path for kanban board state (per
/// cmux-shared-behavior): every entrypoint that moves a card, archives/
/// unarchives, or edits the column list — board drag/drop, card + column
/// context menus, and any future CLI/Command Palette entrypoint — must call
/// through these methods rather than mutating `Workspace.kanbanColumnId` or
/// writing `kanban.columns` inline.
///
/// Per-tab moves mutate the `Workspace` `@Published` fields directly
/// (persisted by the existing 8s autosave/terminate session-snapshot path).
/// Column CRUD writes through the `CmuxSettings` `kanban.columns` JSON
/// setting via the shared `SettingsRuntime` — the exact read/write pair
/// `DevWindowDisplayDefault` uses: `jsonStore.snapshotValue(for:)` for a
/// synchronous read, `try await jsonStore.set(_:for:)` for the write. The
/// pure list transforms (add/rename/recolor/collapse/delete + guard rules)
/// live in `KanbanColumnMutations` (CmuxSettings package) so they're testable
/// without constructing a `TabManager`.
///
/// `KanbanBoardView` observes `tabManager` (not individual workspaces), so
/// every method here that mutates a `Workspace` field calls
/// `objectWillChange.send()` after mutating — otherwise a lone
/// `Workspace.kanbanColumnId` change only fires that workspace's own
/// `objectWillChange`, and the board never re-renders (caught in the Stage 2
/// review). Column-list writes go through `writeKanbanColumns`, which also
/// sends `objectWillChange`; the board's `@LiveSetting(\.kanban.columns)`
/// reacts to the JSON store's own change stream regardless, so that send is
/// belt-and-suspenders there, not load-bearing.
extension TabManager {
    // MARK: - Per-tab column assignment

    /// Assigns `tabId`'s card to `columnId` at fractional position `order`
    /// (cheap reordering within a column without renumbering neighbors).
    func setKanbanColumn(tabId: UUID, columnId: String, order: Double) {
        guard let workspace = workspacesById[tabId] else { return }
        workspace.kanbanColumnId = columnId
        workspace.kanbanOrder = order
        objectWillChange.send()
    }

    /// Moves `tabId`'s card to the end of `columnId` — the "Move to Column"
    /// context-menu path, where there's no drop-neighbor context to place it
    /// between.
    func moveWorkspace(tabId: UUID, toColumn columnId: String) {
        setKanbanColumn(tabId: tabId, columnId: columnId, order: nextOrder(inColumn: columnId))
    }

    /// Moves `tabId`'s card to the Archive column. No-op if there is no
    /// archive column (shouldn't happen; `KanbanColumn.defaults` always seeds
    /// one and it's non-deletable).
    func archiveWorkspace(tabId: UUID) {
        guard let archiveColumnId = KanbanColumnMutations.archiveColumnId(currentKanbanColumns()) else { return }
        moveWorkspace(tabId: tabId, toColumn: archiveColumnId)
    }

    /// Moves `tabId`'s card out of Archive, back to the first non-archive column.
    func unarchiveWorkspace(tabId: UUID) {
        guard let targetColumnId = KanbanColumnMutations.firstNonArchiveColumnId(currentKanbanColumns()) else { return }
        moveWorkspace(tabId: tabId, toColumn: targetColumnId)
    }

    /// Renames a card's underlying workspace (its custom title). Goes through
    /// the shared `setCustomTitle` path, then sends `objectWillChange` so the
    /// board (which observes `tabManager`, not each workspace) re-renders the
    /// card with the new title.
    func renameCard(tabId: UUID, title: String) {
        setCustomTitle(tabId: tabId, title: title)
        objectWillChange.send()
    }

    // MARK: - Column CRUD

    func addKanbanColumn(title: String) {
        let updated = KanbanColumnMutations.addingColumn(currentKanbanColumns(), id: UUID().uuidString, title: title)
        writeKanbanColumns(updated)
    }

    func renameKanbanColumn(id: String, title: String) {
        writeKanbanColumns(KanbanColumnMutations.renamingColumn(currentKanbanColumns(), id: id, title: title))
    }

    func setColumnColor(id: String, colorHex: String?) {
        writeKanbanColumns(KanbanColumnMutations.settingColumnColor(currentKanbanColumns(), id: id, colorHex: colorHex))
    }

    func setColumnCollapsed(id: String, collapsed: Bool) {
        writeKanbanColumns(KanbanColumnMutations.settingColumnCollapsed(currentKanbanColumns(), id: id, collapsed: collapsed))
    }

    /// Deletes column `id`, reassigning every card currently in it BEFORE
    /// removing the column, so no card is ever orphaned into a non-existent
    /// column. See `KanbanColumnMutations.deletingColumn` for the guard rules
    /// (Archive is non-deletable; the last non-archive column can't be
    /// deleted). Returns `false` on refusal.
    @discardableResult
    func deleteKanbanColumn(id: String, reassignTo: String? = nil) -> Bool {
        guard let deletion = KanbanColumnMutations.deletingColumn(currentKanbanColumns(), id: id, reassignTo: reassignTo) else {
            return false
        }
        for tab in tabs where tab.kanbanColumnId == id {
            tab.kanbanColumnId = deletion.reassignedToColumnId
            tab.kanbanOrder = nextOrder(inColumn: deletion.reassignedToColumnId)
        }
        writeKanbanColumns(deletion.columns)
        return true
    }

    // MARK: - Shared column-state helpers

    /// Synchronous snapshot of the current `kanban.columns` setting. Safe to
    /// call from the main actor before any suspension point (mirrors
    /// `DevWindowDisplayDefault.current`'s use of `snapshotValue(for:)`).
    /// Falls back to `KanbanColumn.defaults` if the app has no settings
    /// runtime yet (shouldn't happen outside of very early startup).
    func currentKanbanColumns() -> [KanbanColumn] {
        guard let runtime = AppDelegate.shared?.settingsRuntime else { return KanbanColumn.defaults }
        return runtime.jsonStore.snapshotValue(for: runtime.catalog.kanban.columns)
    }

    /// Fractional order placing a card at the end of `columnId` (max existing
    /// `kanbanOrder` among that column's current cards + 1).
    private func nextOrder(inColumn columnId: String) -> Double {
        let existingOrders = tabs.filter { $0.kanbanColumnId == columnId }.map(\.kanbanOrder)
        return (existingOrders.max() ?? -1) + 1
    }

    /// Persists `columns` through the shared `SettingsRuntime`'s JSON store —
    /// the same store `@LiveSetting(\.kanban.columns)` reads from, so the
    /// board picks up the change via its own hot-reload stream. The write
    /// itself is fire-and-forget (matches `DevWindowDisplayDefault.set`); a
    /// failure is swallowed here the same way that helper does, rather than
    /// surfaced to the caller.
    private func writeKanbanColumns(_ columns: [KanbanColumn]) {
        guard let runtime = AppDelegate.shared?.settingsRuntime else { return }
        Task {
            try? await runtime.jsonStore.set(columns, for: runtime.catalog.kanban.columns)
        }
        objectWillChange.send()
    }
}
