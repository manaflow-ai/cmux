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
@MainActor
struct KanbanBoardView: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var kanbanFocusState: KanbanFocusState
    @Binding var selection: SidebarSelection
    /// Cleared (`false`) the moment the user makes an explicit choice —
    /// clicking a card or using the "Open Focused Card" shortcut — so the
    /// cold-launch board landing (`ContentView`'s `.ghosttyDidFocusTab`
    /// handler) never re-triggers after that. See `SidebarSelectionState`.
    @Binding var isInitialBoardLanding: Bool
    @LiveSetting(\.kanban.columns) private var columns: [KanbanColumn]
    /// Drives keyboard focus onto the board so arrow-key navigation works
    /// without an extra click: granted whenever the board becomes the
    /// visible selection (see the `.onChange(of: selection)` below), since
    /// `.focusable()` alone doesn't auto-focus a view.
    @FocusState private var isBoardFocused: Bool

    var body: some View {
        let sortedColumns = columns.sorted { $0.order < $1.order }
        let columnSnapshots = sortedColumns.map { KanbanColumnSnapshot(column: $0, displayTitle: displayTitle(for: $0)) }
        let cardsByColumnId = bucketedCards(sortedColumns: sortedColumns)
        let columnActions = self.columnActions(sortedColumns: sortedColumns)
        let focusedCardId = kanbanFocusState.focusedCardId

        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(sortedColumns) { column in
                    KanbanColumnView(
                        column: KanbanColumnSnapshot(column: column, displayTitle: displayTitle(for: column)),
                        cards: cardsByColumnId[column.id] ?? [],
                        allColumns: columnSnapshots,
                        focusedCardId: focusedCardId,
                        actions: columnActions
                    )
                    .equatable()
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Bare arrow keys can't be bound as cmux shortcuts (the recorder
        // requires a modifier on the first stroke), so board focus
        // navigation is handled directly here instead of through
        // `KeyboardShortcutSettings` — the modifier-bearing open/move/archive
        // actions below ARE real cmux shortcuts (see `TabManager+Kanban` /
        // `AppDelegate`'s board dispatch block).
        .focusable()
        .focused($isBoardFocused)
        .onKeyPress(.leftArrow) {
            moveFocusToAdjacentColumn(delta: -1, sortedColumns: sortedColumns, cardsByColumnId: cardsByColumnId)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveFocusToAdjacentColumn(delta: 1, sortedColumns: sortedColumns, cardsByColumnId: cardsByColumnId)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveFocusWithinColumn(delta: -1, sortedColumns: sortedColumns, cardsByColumnId: cardsByColumnId)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveFocusWithinColumn(delta: 1, sortedColumns: sortedColumns, cardsByColumnId: cardsByColumnId)
            return .handled
        }
        .onAppear {
            ensureValidFocus(sortedColumns: sortedColumns, cardsByColumnId: cardsByColumnId)
            if selection == .board {
                isBoardFocused = true
            }
        }
        .onChange(of: selection) { _, newSelection in
            if newSelection == .board {
                isBoardFocused = true
            }
        }
    }

    // MARK: - Keyboard focus navigation

    /// Moves keyboard focus to the previous (`delta: -1`) or next (`delta:
    /// 1`) column, at the same relative card index (clamped to that
    /// column's card count). Collapsed columns are skipped — their cards
    /// aren't rendered, so they can't receive focus. Falls back to focusing
    /// the first card of the first navigable column when nothing is
    /// currently focused (or the focused card no longer exists / its column
    /// just collapsed — the same "stale focus" case).
    private func moveFocusToAdjacentColumn(
        delta: Int,
        sortedColumns: [KanbanColumn],
        cardsByColumnId: [String: [KanbanCardSnapshot]]
    ) {
        let navigableColumns = sortedColumns.filter { !$0.isCollapsed }
        guard let focusedCardId = kanbanFocusState.focusedCardId,
              let currentColumnIndex = navigableColumns.firstIndex(where: { column in
                  cardsByColumnId[column.id]?.contains(where: { $0.id == focusedCardId }) == true
              }) else {
            focusFirstCard(sortedColumns: navigableColumns, cardsByColumnId: cardsByColumnId)
            return
        }
        let currentCards = cardsByColumnId[navigableColumns[currentColumnIndex].id] ?? []
        let rowIndex = currentCards.firstIndex(where: { $0.id == focusedCardId }) ?? 0
        let targetColumnIndex = min(max(currentColumnIndex + delta, 0), navigableColumns.count - 1)
        guard targetColumnIndex != currentColumnIndex else { return }
        let targetCards = cardsByColumnId[navigableColumns[targetColumnIndex].id] ?? []
        guard !targetCards.isEmpty else { return }
        kanbanFocusState.focusedCardId = targetCards[min(rowIndex, targetCards.count - 1)].id
    }

    /// Moves keyboard focus to the previous (`delta: -1`) or next (`delta:
    /// 1`) card within the currently focused column (clamped).
    private func moveFocusWithinColumn(
        delta: Int,
        sortedColumns: [KanbanColumn],
        cardsByColumnId: [String: [KanbanCardSnapshot]]
    ) {
        let navigableColumns = sortedColumns.filter { !$0.isCollapsed }
        guard let focusedCardId = kanbanFocusState.focusedCardId,
              let column = navigableColumns.first(where: { cardsByColumnId[$0.id]?.contains(where: { $0.id == focusedCardId }) == true }),
              let cards = cardsByColumnId[column.id],
              let rowIndex = cards.firstIndex(where: { $0.id == focusedCardId }) else {
            focusFirstCard(sortedColumns: navigableColumns, cardsByColumnId: cardsByColumnId)
            return
        }
        let targetIndex = min(max(rowIndex + delta, 0), cards.count - 1)
        kanbanFocusState.focusedCardId = cards[targetIndex].id
    }

    private func focusFirstCard(sortedColumns: [KanbanColumn], cardsByColumnId: [String: [KanbanCardSnapshot]]) {
        for column in sortedColumns {
            if let firstCard = cardsByColumnId[column.id]?.first {
                kanbanFocusState.focusedCardId = firstCard.id
                return
            }
        }
        kanbanFocusState.focusedCardId = nil
    }

    /// Called once from `.onAppear` (the board stays mounted and only
    /// cross-fades opacity, so this fires on first launch, not every visit).
    /// Seeds focus to the first card of the first column when nothing is
    /// focused yet, or when the previously focused card no longer exists.
    private func ensureValidFocus(sortedColumns: [KanbanColumn], cardsByColumnId: [String: [KanbanCardSnapshot]]) {
        if let focusedCardId = kanbanFocusState.focusedCardId,
           cardsByColumnId.values.contains(where: { $0.contains(where: { $0.id == focusedCardId }) }) {
            return
        }
        focusFirstCard(sortedColumns: sortedColumns, cardsByColumnId: cardsByColumnId)
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
        isInitialBoardLanding = false
    }
}
