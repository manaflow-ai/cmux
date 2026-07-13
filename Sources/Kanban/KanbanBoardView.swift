import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// Top-level kanban board: the `.board` layer `ContentView.terminalContent(appearance:)`
/// cross-fades against `.tabs`/`.notifications`, exactly like `NotificationsPage`.
///
/// Mirrors `NotificationsPage`: a plain `@EnvironmentObject var tabManager` for the
/// live workspace list plus a `@Binding` back to the shared selection, rather than
/// holding `SidebarSelectionState` itself. Columns come from the `kanban.columns`
/// JSON setting via `@LiveSetting`, which hot-reloads on external `cmux.json` edits.
///
/// Everything below the column `ForEach` receives immutable value snapshots plus a
/// closure action bundle only — no `Workspace`/`TabManager` reference passes the
/// boundary. See `IndexSectionActions`/`SectionGapActions` in
/// `Sources/SessionIndexView.swift` for the reference pattern this follows.
///
/// Every mutation (move, archive, column CRUD) routes through `TabManager+Kanban`
/// — the one shared action path per cmux-shared-behavior — so drag/drop, the
/// card/column context menus, and any future CLI/Command Palette entrypoint stay
/// in lockstep.
struct KanbanBoardView: View {
    @EnvironmentObject var tabManager: TabManager
    @Binding var selection: SidebarSelection
    @LiveSetting(\.kanban.columns) private var columns: [KanbanColumn]

    var body: some View {
        let sortedColumns = columns.sorted { $0.order < $1.order }
        let columnSnapshots = sortedColumns.map { KanbanColumnSnapshot(column: $0, displayTitle: displayTitle(for: $0)) }
        let cardsByColumnId = bucketedCards(sortedColumns: sortedColumns)
        let columnActions = self.columnActions(sortedColumns: sortedColumns)

        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(sortedColumns) { column in
                    KanbanColumnView(
                        column: KanbanColumnSnapshot(column: column, displayTitle: displayTitle(for: column)),
                        cards: cardsByColumnId[column.id] ?? [],
                        allColumns: columnSnapshots,
                        actions: columnActions
                    )
                    .equatable()
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Resolves the title to render for `column`. The seeded default column
    /// ids (todo/in-progress/done/archive) get a localized display title; any
    /// other column — user-created, or a seeded column the user renamed —
    /// falls back to its stored `title` verbatim. Config is never rewritten
    /// by this: `kanban.columns` in cmux.json always keeps the plain seed
    /// text, and only the id is stable, per the plan's "store a stable
    /// non-localized id, localize only the display title."
    private func displayTitle(for column: KanbanColumn) -> String {
        // Only resolve to the localized title when the stored title still
        // matches the (always-English) seed default for this id — otherwise
        // the user renamed it, and their text wins.
        guard let seedDefault = KanbanColumn.defaults.first(where: { $0.id == column.id }),
              column.title == seedDefault.title else {
            return column.title
        }
        switch column.id {
        case "todo":
            return String(localized: "kanban.column.title.todo", defaultValue: "To Do")
        case "in-progress":
            return String(localized: "kanban.column.title.inProgress", defaultValue: "In Progress")
        case "done":
            return String(localized: "kanban.column.title.done", defaultValue: "Done")
        case "archive":
            return String(localized: "kanban.column.title.archive", defaultValue: "Archive")
        default:
            return column.title
        }
    }

    /// Buckets every workspace into its assigned column, sorted within the
    /// column by `kanbanOrder` (so drag/drop-driven reordering is reflected).
    /// A workspace whose `kanbanColumnId` is nil, or points at a column that
    /// no longer exists (e.g. deleted in a later stage), falls back to the
    /// first non-archive column so it's never silently dropped off the board.
    private func bucketedCards(sortedColumns: [KanbanColumn]) -> [String: [KanbanCardSnapshot]] {
        let knownColumnIds = Set(sortedColumns.map(\.id))
        let defaultColumnId = KanbanColumnMutations.firstNonArchiveColumnId(sortedColumns)
        var result: [String: [KanbanCardSnapshot]] = [:]
        for tab in tabManager.tabs {
            let assignedColumnId = tab.kanbanColumnId.flatMap { knownColumnIds.contains($0) ? $0 : nil }
            guard let columnId = assignedColumnId ?? defaultColumnId else { continue }
            result[columnId, default: []].append(KanbanCardSnapshot(workspace: tab))
        }
        for key in result.keys {
            result[key]?.sort { $0.order < $1.order }
        }
        return result
    }

    /// The action bundle every column/card below the `ForEach` boundary
    /// invokes instead of touching `tabManager`/the kanban store directly.
    /// Every closure routes to a `TabManager+Kanban` method.
    private func columnActions(sortedColumns: [KanbanColumn]) -> KanbanColumnActions {
        KanbanColumnActions(
            onCardTap: selectWorkspace,
            onToggleCollapsed: { columnId in
                let isCollapsed = sortedColumns.first(where: { $0.id == columnId })?.isCollapsed ?? false
                tabManager.setColumnCollapsed(id: columnId, collapsed: !isCollapsed)
            },
            onCardDropped: { tabId, targetColumnId, dropOrder in
                tabManager.setKanbanColumn(tabId: tabId, columnId: targetColumnId, order: dropOrder)
            },
            onMoveCardToColumn: { tabId, columnId in
                tabManager.moveWorkspace(tabId: tabId, toColumn: columnId)
            },
            onArchiveCard: { tabId in tabManager.archiveWorkspace(tabId: tabId) },
            onUnarchiveCard: { tabId in tabManager.unarchiveWorkspace(tabId: tabId) },
            onRenameColumn: { id, title in tabManager.renameKanbanColumn(id: id, title: title) },
            onSetColumnColor: { id, colorHex in tabManager.setColumnColor(id: id, colorHex: colorHex) },
            onDeleteColumn: { id in tabManager.deleteKanbanColumn(id: id) },
            onAddColumn: { title in tabManager.addKanbanColumn(title: title) }
        )
    }

    private func selectWorkspace(_ workspaceId: UUID) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
        tabManager.selectWorkspace(workspace)
        selection = .tabs
    }
}
