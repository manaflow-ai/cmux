import CmuxFoundation
import SwiftUI

/// Immutable per-card value snapshot of a `Workspace`, computed once at the
/// board root (`KanbanBoardView`). `KanbanCardView` never holds a `Workspace`
/// reference, so a `kanbanColumnId`/title/color change elsewhere can't cascade
/// a re-render into every other card below the board's `ForEach` boundary.
struct KanbanCardSnapshot: Identifiable, Equatable {
    let id: UUID
    let title: String
    let colorHex: String?
    /// Fractional position within its column (`Workspace.kanbanOrder`). Used
    /// by `KanbanBoardView` to sort each column's cards and by the column's
    /// drop delegate to compute "place at end of column".
    let order: Double

    init(workspace: Workspace) {
        id = workspace.id
        title = workspace.customTitle ?? workspace.title
        colorHex = workspace.customColor
        order = workspace.kanbanOrder
    }
}

/// One kanban card = one workspace. Tapping it selects the workspace and
/// jumps back to the terminal view (`KanbanBoardView.selectWorkspace`).
/// Dragging it (`.onDrag`) reuses the existing `com.cmux.sidebar-tab-reorder`
/// payload (`SidebarTabDragPayload`) so `KanbanColumnView`'s drop delegate can
/// decode the same wire format the sidebar already uses.
///
/// Follows the `.equatable()` value pattern of `TabItemView`
/// (`Sources/ContentView.swift:13078`): closures are excluded from `==`,
/// since they're recreated every parent eval but don't affect rendering;
/// `otherColumns`/`isInArchiveColumn` are plain data, so they ARE compared.
struct KanbanCardView: View, Equatable {
    let card: KanbanCardSnapshot
    let onTap: () -> Void
    /// Non-archive columns other than this card's own, for the "Move to
    /// Column" submenu. Passed as a value snapshot (not the board's
    /// `[KanbanColumn]`) so this view stays below the snapshot boundary.
    let otherColumns: [KanbanColumnSnapshot]
    /// Whether this card currently sits in the Archive column — swaps the
    /// context menu's "Archive" item for "Move Out of Archive".
    let isInArchiveColumn: Bool
    let onMoveToColumn: (String) -> Void
    let onArchive: () -> Void
    let onUnarchive: () -> Void

    static func == (lhs: KanbanCardView, rhs: KanbanCardView) -> Bool {
        lhs.card == rhs.card &&
        lhs.otherColumns == rhs.otherColumns &&
        lhs.isInArchiveColumn == rhs.isInArchiveColumn
    }

    var body: some View {
        HStack(spacing: 8) {
            if let colorHex = card.colorHex, let color = Color(hex: colorHex) {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(card.title)
                .cmuxFont(.body)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onDrag {
            SidebarTabDragPayload(tabId: card.id).provider()
        }
        .contextMenu {
            if isInArchiveColumn {
                Button(String(localized: "kanban.card.unarchive", defaultValue: "Move Out of Archive")) {
                    onUnarchive()
                }
            } else {
                if !otherColumns.isEmpty {
                    Menu(String(localized: "kanban.card.moveToColumn", defaultValue: "Move to Column")) {
                        ForEach(otherColumns) { column in
                            Button(column.title) { onMoveToColumn(column.id) }
                        }
                    }
                }
                Button(String(localized: "kanban.card.archive", defaultValue: "Archive")) {
                    onArchive()
                }
            }
        }
    }
}
