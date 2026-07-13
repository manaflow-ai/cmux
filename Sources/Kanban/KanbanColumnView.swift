import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI
import UniformTypeIdentifiers

/// Immutable value snapshot of a `KanbanColumn`, computed once at the board
/// root. `KanbanColumnView` never touches `KanbanColumn`/`CmuxSettings`
/// directly so it stays a plain value-in, value-out row below the board's
/// `ForEach` boundary.
struct KanbanColumnSnapshot: Identifiable, Equatable {
    let id: String
    let title: String
    let order: Int
    let colorHex: String?
    let isArchive: Bool
    let isCollapsed: Bool

    /// - Parameter displayTitle: The title to render, already resolved by the
    ///   caller (`KanbanBoardView.displayTitle(for:)`). The seeded default
    ///   columns (todo/in-progress/done/archive) get a localized title; any
    ///   other (user-created) column keeps its stored `title` verbatim.
    ///   Defaults to `column.title` so call sites that don't need the
    ///   resolver still work.
    init(column: KanbanColumn, displayTitle: String? = nil) {
        id = column.id
        title = displayTitle ?? column.title
        order = column.order
        colorHex = column.colorHex
        isArchive = column.isArchive
        isCollapsed = column.isCollapsed
    }
}

/// Closure bundle handed to `KanbanColumnView` in place of a `TabManager` or
/// kanban config store reference, so nothing below the board's column
/// `ForEach` can observe those stores directly. Mirrors `IndexSectionActions`
/// in `Sources/SessionIndexView.swift`. Every closure here routes to a
/// `TabManager+Kanban` method — the one shared mutation path per
/// cmux-shared-behavior — so drag/drop and the context menus below can never
/// drift from each other.
struct KanbanColumnActions {
    let onCardTap: (UUID) -> Void
    let onToggleCollapsed: (String) -> Void
    /// A card was dropped on this column: the tab id, the target column id,
    /// and the fractional order to place it at (computed by the column's drop
    /// delegate — end-of-column for Stage 3, no inter-card gap detection).
    let onCardDropped: (_ tabId: UUID, _ targetColumnId: String, _ dropOrder: Double) -> Void
    /// "Move to Column" context-menu path (no drop-neighbor context, so the
    /// card lands at the end of the target column).
    let onMoveCardToColumn: (_ tabId: UUID, _ columnId: String) -> Void
    let onArchiveCard: (UUID) -> Void
    let onUnarchiveCard: (UUID) -> Void
    let onRenameColumn: (_ id: String, _ title: String) -> Void
    let onSetColumnColor: (_ id: String, _ colorHex: String?) -> Void
    let onDeleteColumn: (_ id: String) -> Void
    let onAddColumn: (_ title: String) -> Void
}

/// One kanban column: header (title, card count, color accent, collapse
/// chevron, context menu) plus a vertical list of cards and a drop target for
/// card moves. The Archive column is pinned last by the board sorting
/// columns by `order` (its default `order` is highest); when collapsed, only
/// the header renders.
struct KanbanColumnView: View, Equatable {
    let column: KanbanColumnSnapshot
    let cards: [KanbanCardSnapshot]
    /// Every column on the board, for this column's cards' "Move to Column"
    /// submenus and for this column's own delete-guard check. A value
    /// snapshot array, not the board's live `[KanbanColumn]` — stays below
    /// the snapshot boundary.
    let allColumns: [KanbanColumnSnapshot]
    let actions: KanbanColumnActions

    @State private var isDropTargeted = false

    /// Preset swatches for the "Set Color" menu — self-contained rather than
    /// reusing `WorkspaceTabColorSettings` (a different settings domain), per
    /// the Stage 3 brief's "a small preset menu" fallback.
    private static let presetColors = [
        "#E53935", "#FB8C00", "#FDD835", "#43A047", "#00ACC1", "#1E88E5", "#8E24AA", "#6D4C41",
    ]

    /// `actions` holds closures (not comparable) and is expected to be stable
    /// across the board's re-renders, so it's excluded here — the same
    /// tradeoff `IndexSectionView.==` makes for its `actions` bundle.
    static func == (lhs: KanbanColumnView, rhs: KanbanColumnView) -> Bool {
        lhs.column == rhs.column && lhs.cards == rhs.cards && lhs.allColumns == rhs.allColumns
    }

    /// Keep >=1 real column: refuse deleting the Archive column (checked
    /// separately by `TabManager+Kanban`, but mirrored here so the menu item
    /// is disabled up front) or the last remaining non-archive column.
    private var canDelete: Bool {
        !column.isArchive && allColumns.filter { !$0.isArchive }.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !column.isCollapsed {
                cardList
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(isDropTargeted ? Color.accentColor.opacity(0.15) : Color(nsColor: .underPageBackgroundColor))
        .cornerRadius(10)
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: KanbanColumnDropDelegate(
            targetColumnId: column.id,
            nextOrder: (cards.map(\.order).max() ?? -1) + 1,
            isTargeted: $isDropTargeted,
            onCardDropped: actions.onCardDropped
        ))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let colorHex = column.colorHex, let color = Color(hex: colorHex) {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(column.title)
                .cmuxFont(.headline)
                .lineLimit(1)
            Text("\(cards.count)")
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Button {
                actions.onToggleCollapsed(column.id)
            } label: {
                Image(systemName: column.isCollapsed ? "chevron.right" : "chevron.down")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                column.isCollapsed
                    ? String(localized: "kanban.column.expand", defaultValue: "Expand column")
                    : String(localized: "kanban.column.collapse", defaultValue: "Collapse column")
            )
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "kanban.column.rename", defaultValue: "Rename Column…")) {
                promptRenameColumn()
            }

            Menu(String(localized: "kanban.column.setColor", defaultValue: "Set Color")) {
                if column.colorHex != nil {
                    Button(String(localized: "kanban.column.clearColor", defaultValue: "Clear Color")) {
                        actions.onSetColumnColor(column.id, nil)
                    }
                    Divider()
                }
                ForEach(Self.presetColors, id: \.self) { hex in
                    Button {
                        actions.onSetColumnColor(column.id, hex)
                    } label: {
                        Label {
                            Text(hex)
                        } icon: {
                            Circle().fill(Color(hex: hex) ?? .gray).frame(width: 10, height: 10)
                        }
                    }
                }
                Divider()
                Button(String(localized: "kanban.column.customColor", defaultValue: "Custom Color…")) {
                    promptCustomColumnColor()
                }
            }

            Divider()

            Button(String(localized: "kanban.column.new", defaultValue: "New Column…")) {
                promptNewColumn()
            }

            if !column.isArchive {
                Button(role: .destructive) {
                    promptDeleteColumn()
                } label: {
                    Text(String(localized: "kanban.column.delete", defaultValue: "Delete Column"))
                }
                .disabled(!canDelete)
            }
        }
    }

    private var cardList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(cards) { card in
                    KanbanCardView(
                        card: card,
                        onTap: { actions.onCardTap(card.id) },
                        otherColumns: allColumns.filter { $0.id != column.id && !$0.isArchive },
                        isInArchiveColumn: column.isArchive,
                        onMoveToColumn: { targetId in actions.onMoveCardToColumn(card.id, targetId) },
                        onArchive: { actions.onArchiveCard(card.id) },
                        onUnarchive: { actions.onUnarchiveCard(card.id) }
                    )
                    .equatable()
                }
            }
        }
    }

    // MARK: - AppKit prompts

    /// Mirrors `promptRename()` (`Sources/ContentView.swift:14854`): an
    /// `NSAlert` with an `NSTextField` accessory, run modally from a
    /// SwiftUI context-menu Button action — the app's existing lightweight
    /// text-prompt pattern.
    private func promptRenameColumn() {
        let alert = NSAlert()
        alert.messageText = String(localized: "kanban.column.rename.title", defaultValue: "Rename Column")
        alert.informativeText = String(localized: "kanban.column.rename.message", defaultValue: "Enter a new name for this column.")
        let input = NSTextField(string: column.title)
        input.placeholderString = String(localized: "kanban.column.rename.placeholder", defaultValue: "Column name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "kanban.column.rename.confirm", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "kanban.column.rename.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actions.onRenameColumn(column.id, trimmed)
    }

    private func promptNewColumn() {
        let alert = NSAlert()
        alert.messageText = String(localized: "kanban.column.new.title", defaultValue: "New Column")
        alert.informativeText = String(localized: "kanban.column.new.message", defaultValue: "Enter a name for the new column.")
        let input = NSTextField(string: "")
        input.placeholderString = String(localized: "kanban.column.new.placeholder", defaultValue: "Column name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "kanban.column.new.confirm", defaultValue: "Add"))
        alert.addButton(withTitle: String(localized: "kanban.column.new.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actions.onAddColumn(trimmed)
    }

    /// Mirrors `promptCustomColor(targetIds:)` (`Sources/ContentView.swift:14811`).
    private func promptCustomColumnColor() {
        let alert = NSAlert()
        alert.messageText = String(localized: "kanban.column.customColor.title", defaultValue: "Custom Column Color")
        alert.informativeText = String(localized: "kanban.column.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")
        let input = NSTextField(string: column.colorHex ?? "")
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "kanban.column.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "kanban.column.customColor.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Color(hex: trimmed) != nil else {
            showInvalidColumnColorAlert(trimmed)
            return
        }
        actions.onSetColumnColor(column.id, trimmed)
    }

    private func showInvalidColumnColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "kanban.column.customColor.invalid.title", defaultValue: "Invalid Color")
        if value.isEmpty {
            alert.informativeText = String(localized: "kanban.column.customColor.invalid.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(
                format: String(localized: "kanban.column.customColor.invalid.message", defaultValue: "\"%@\" is not a valid hex color. Use #RRGGBB."),
                value
            )
        }
        alert.addButton(withTitle: String(localized: "kanban.column.customColor.invalid.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    private func promptDeleteColumn() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "kanban.column.delete.title", defaultValue: "Delete \"%@\"?"),
            column.title
        )
        alert.informativeText = String(localized: "kanban.column.delete.message", defaultValue: "Cards in this column will move to another column. This can't be undone.")
        alert.addButton(withTitle: String(localized: "kanban.column.delete.confirm", defaultValue: "Delete"))
        alert.addButton(withTitle: String(localized: "kanban.column.delete.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        actions.onDeleteColumn(column.id)
    }
}

/// Drop target for card moves onto a kanban column. Decodes the same
/// `com.cmux.sidebar-tab-reorder` payload the sidebar already produces
/// (`SidebarTabDragPayload`) rather than hand-rolling a new wire format.
/// Holds no store reference — just the target column id, the order to place
/// a dropped card at, and the board-root-provided mutation closure.
@MainActor
private struct KanbanColumnDropDelegate: DropDelegate {
    let targetColumnId: String
    let nextOrder: Double
    @Binding var isTargeted: Bool
    let onCardDropped: (_ tabId: UUID, _ targetColumnId: String, _ dropOrder: Double) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: SidebarTabDragPayload.dropContentTypes)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: SidebarTabDragPayload.dropContentTypes).first else {
            return false
        }
        let columnId = targetColumnId
        let order = nextOrder
        provider.loadDataRepresentation(forTypeIdentifier: SidebarTabDragPayload.typeIdentifier) { data, _ in
            guard let data,
                  let payload = String(data: data, encoding: .utf8),
                  payload.hasPrefix(SidebarTabDragPayload.prefix),
                  let tabId = UUID(uuidString: String(payload.dropFirst(SidebarTabDragPayload.prefix.count)))
            else { return }
            Task { @MainActor in
                onCardDropped(tabId, columnId, order)
            }
        }
        return true
    }
}
