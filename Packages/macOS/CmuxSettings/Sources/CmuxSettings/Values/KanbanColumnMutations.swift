import Foundation

/// Pure transforms over a `[KanbanColumn]` list: add/rename/recolor/collapse/
/// delete, plus the guard rules ("keep >=1 real column", "Archive is
/// non-deletable") and default-column resolution. No `TabManager`/`Workspace`/
/// settings-store dependency, so this behavior is covered by tests without
/// constructing the app's runtime.
///
/// `TabManager+Kanban` (the app target's shared mutation path, per
/// cmux-shared-behavior) calls these, then persists the resulting list through
/// `SettingsRuntime.jsonStore` and — for ``deletingColumn(_:id:reassignTo:)`` —
/// reassigns the affected `Workspace`s to ``ColumnDeletion/reassignedToColumnId``.
public enum KanbanColumnMutations {
    /// Appends a new column titled `title` after every existing column (max
    /// `order` + 1). `id` is caller-supplied (a fresh UUID string in
    /// production) so this stays deterministic for tests.
    public static func addingColumn(_ columns: [KanbanColumn], id: String, title: String) -> [KanbanColumn] {
        let newOrder = (columns.map(\.order).max() ?? -1) + 1
        return columns + [KanbanColumn(id: id, title: title, order: newOrder)]
    }

    /// Renames column `id`. No-op (returns `columns` unchanged) if `id` isn't found.
    public static func renamingColumn(_ columns: [KanbanColumn], id: String, title: String) -> [KanbanColumn] {
        columns.map { column in
            guard column.id == id else { return column }
            var updated = column
            updated.title = title
            return updated
        }
    }

    /// Sets (or clears, with `colorHex: nil`) column `id`'s color.
    public static func settingColumnColor(_ columns: [KanbanColumn], id: String, colorHex: String?) -> [KanbanColumn] {
        columns.map { column in
            guard column.id == id else { return column }
            var updated = column
            updated.colorHex = colorHex
            return updated
        }
    }

    /// Sets column `id`'s collapsed state.
    public static func settingColumnCollapsed(_ columns: [KanbanColumn], id: String, collapsed: Bool) -> [KanbanColumn] {
        columns.map { column in
            guard column.id == id else { return column }
            var updated = column
            updated.isCollapsed = collapsed
            return updated
        }
    }

    /// The result of a successful ``deletingColumn(_:id:reassignTo:)`` call:
    /// the column list with `id` removed, and the column every one of its
    /// cards must be reassigned to.
    public struct ColumnDeletion: Equatable {
        public let columns: [KanbanColumn]
        public let reassignedToColumnId: String
    }

    /// Deletes column `id`. Refuses (returns `nil`) when `id` is the Archive
    /// column (non-deletable, but renamable/recolorable/collapsible) or the
    /// last remaining non-archive column (keep >=1 real column at all times).
    /// A refusal never silently no-ops a delete the user asked for — the
    /// caller must check for `nil` and surface it.
    ///
    /// `reassignTo`, when it names a column that will still exist after the
    /// delete, is used as the reassignment target; otherwise the first
    /// remaining non-archive column (by `order`) is used. The caller must
    /// apply the reassignment to every card BEFORE removing the column, so no
    /// card is ever orphaned into a non-existent column id.
    public static func deletingColumn(
        _ columns: [KanbanColumn],
        id: String,
        reassignTo: String? = nil
    ) -> ColumnDeletion? {
        guard let target = columns.first(where: { $0.id == id }), !target.isArchive else { return nil }
        let remaining = columns.filter { $0.id != id }
        let remainingNonArchive = remaining.filter { !$0.isArchive }
        guard !remainingNonArchive.isEmpty else { return nil }
        let resolvedTarget = reassignTo
            .flatMap { candidate in remainingNonArchive.first(where: { $0.id == candidate })?.id }
            ?? remainingNonArchive.sorted(by: { $0.order < $1.order })[0].id
        return ColumnDeletion(columns: remaining, reassignedToColumnId: resolvedTarget)
    }

    /// The first non-archive column by `order` — the default landing column
    /// for a card with no assignment (or one pointing at a deleted column).
    /// `nil` only if every column is archive (shouldn't happen in practice;
    /// guarded against by ``deletingColumn(_:id:reassignTo:)``).
    public static func firstNonArchiveColumnId(_ columns: [KanbanColumn]) -> String? {
        columns.filter { !$0.isArchive }.sorted { $0.order < $1.order }.first?.id
    }

    /// The Archive column's id, or `nil` if none is configured.
    public static func archiveColumnId(_ columns: [KanbanColumn]) -> String? {
        columns.first(where: \.isArchive)?.id
    }
}
