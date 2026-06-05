import AppKit
import SwiftUI

/// Browses the closed-item history (closed terminals, browsers, panes, workspaces,
/// and windows) grouped by destructive operation, and lets the user reopen or
/// forget any entry. This is the History pane's content, distinct from the
/// agent-session "Vault".
///
/// Each destructive action is one operation (a single close, or a multi-select
/// delete of N items). Operations render as collapsible groups; users can select
/// exactly which entries to restore instead of triggering a broad restore-all.
///
/// Follows the snapshot-boundary rule (https://github.com/manaflow-ai/cmux/issues/2586):
/// the store is observed only here; rows receive immutable value snapshots plus
/// closures, never the store itself.
struct ClosedItemsHistoryView: View {
    @ObservedObject var store: ClosedItemHistoryStore
    /// Reopen a single item by its record id (non-destructive).
    let onReopen: (UUID) -> Void
    /// Remove a single item from history by its record id.
    let onDelete: (UUID) -> Void
    let onClearAll: () -> Void

    @State private var collapsed: Set<UUID> = []
    @State private var selectedItemIds: Set<UUID> = []

    var body: some View {
        let operations = store.operationSnapshot()
        let totalItems = operations.reduce(0) { $0 + $1.items.count }
        let onReopen = self.onReopen
        let onDelete = self.onDelete
        let selectedRestorableIds = operations
            .flatMap(\.items)
            .filter { !$0.isRestored && selectedItemIds.contains($0.id) }
            .map(\.id)

        return VStack(spacing: 0) {
            header(count: totalItems, selectedRestorableIds: selectedRestorableIds)
            if operations.isEmpty {
                emptyView
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(operations) { op in
                            ClosedOperationGroup(
                                operation: op,
                                isCollapsed: collapsed.contains(op.id),
                                onToggleCollapse: { toggle(op.id) },
                                onReopenItem: onReopen,
                                onDeleteItem: onDelete,
                                selectedItemIds: selectedItemIds,
                                onToggleSelection: { toggleSelection($0) },
                                onSelectItems: { selectItems($0) },
                                onDeselectItems: { deselectItems($0) }
                            )
                            .id(op.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .modifier(ClearScrollBackground())
            }
        }
    }

    private func toggle(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedItemIds.contains(id) { selectedItemIds.remove(id) } else { selectedItemIds.insert(id) }
    }

    private func selectItems(_ ids: [UUID]) {
        selectedItemIds.formUnion(ids)
    }

    private func deselectItems(_ ids: [UUID]) {
        selectedItemIds.subtract(ids)
    }

    private func header(count: Int, selectedRestorableIds: [UUID]) -> some View {
        let onReopen = self.onReopen
        return HStack(spacing: 8) {
            Text(String(localized: "historyPane.header.title", defaultValue: "History"))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            if !selectedRestorableIds.isEmpty {
                Button {
                    deselectItems(selectedRestorableIds)
                    for id in selectedRestorableIds { onReopen(id) }
                } label: {
                    Text(restoreSelectedTitle(count: selectedRestorableIds.count))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "historyPane.restoreSelected.tooltip", defaultValue: "Restore selected closed items"))
            }
            if count > 0 {
                Button {
                    selectedItemIds.removeAll()
                    onClearAll()
                } label: {
                    Text(String(localized: "historyPane.clearAll", defaultValue: "Clear All"))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "historyPane.clearAll.tooltip", defaultValue: "Remove all items from history"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private func restoreSelectedTitle(count: Int) -> String {
        let format = String(localized: "historyPane.restoreSelected", defaultValue: "Restore %d")
        return String.localizedStringWithFormat(format, count)
    }

    private var emptyView: some View {
        VStack(spacing: 4) {
            Text(String(localized: "historyPane.empty.title", defaultValue: "Nothing closed yet"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(String(localized: "historyPane.empty.subtitle",
                        defaultValue: "Closed tabs, workspaces, and windows show up here. Reopen any of them."))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renders one operation: a single row for a singleton close, or a collapsible
/// group header plus child rows for a multi-item operation.
private struct ClosedOperationGroup: View, Equatable {
    let operation: ClosedOperationSnapshot
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onReopenItem: (UUID) -> Void
    let onDeleteItem: (UUID) -> Void
    let selectedItemIds: Set<UUID>
    let onToggleSelection: (UUID) -> Void
    let onSelectItems: ([UUID]) -> Void
    let onDeselectItems: ([UUID]) -> Void

    static func == (lhs: ClosedOperationGroup, rhs: ClosedOperationGroup) -> Bool {
        lhs.operation == rhs.operation &&
            lhs.isCollapsed == rhs.isCollapsed &&
            lhs.selectedItemIds == rhs.selectedItemIds
    }

    var body: some View {
        if operation.isSingleton, let item = operation.items.first {
            ClosedItemRow(
                item: item,
                indented: false,
                isSelected: selectedItemIds.contains(item.id),
                onToggleSelection: { onToggleSelection(item.id) },
                onReopen: { onReopenItem(item.id) },
                onDelete: { onDeleteItem(item.id) }
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                groupHeader
                if !isCollapsed {
                    ForEach(operation.items) { item in
                        ClosedItemRow(
                            item: item,
                            indented: true,
                            isSelected: selectedItemIds.contains(item.id),
                            onToggleSelection: { onToggleSelection(item.id) },
                            onReopen: { onReopenItem(item.id) },
                            onDelete: { onDeleteItem(item.id) }
                        )
                    }
                }
            }
        }
    }

    private var groupHeader: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCollapse) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            groupSelectionControl
            Image(systemName: "rectangle.stack")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(operation.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(operation.isFullyRestored ? .secondary : .primary.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { onToggleCollapse() }
    }

    private var restorableItemIds: [UUID] {
        operation.items.filter { !$0.isRestored }.map(\.id)
    }

    private var selectedRestorableItemIds: [UUID] {
        restorableItemIds.filter { selectedItemIds.contains($0) }
    }

    @ViewBuilder
    private var groupSelectionControl: some View {
        if restorableItemIds.isEmpty {
            Image(systemName: "checkmark.square")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.45))
                .frame(width: 14)
        } else {
            let selectedCount = selectedRestorableItemIds.count
            let imageName = selectedCount == restorableItemIds.count
                ? "checkmark.square.fill"
                : selectedCount > 0 ? "minus.square.fill" : "square"
            Button {
                if selectedCount == restorableItemIds.count {
                    onDeselectItems(restorableItemIds)
                } else {
                    onSelectItems(restorableItemIds.filter { !selectedItemIds.contains($0) })
                }
            } label: {
                Image(systemName: imageName)
                    .font(.system(size: 12))
                    .foregroundColor(selectedCount > 0 ? .accentColor : .secondary.opacity(0.75))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(String(localized: "historyPane.group.select", defaultValue: "Select group for restore"))
        }
    }
}

/// A single closed-item row. Value-snapshot + closures only; never observes the store.
private struct ClosedItemRow: View, Equatable {
    let item: ClosedItemHistoryMenuItem
    let indented: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onReopen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    static func == (lhs: ClosedItemRow, rhs: ClosedItemRow) -> Bool {
        lhs.item == rhs.item && lhs.indented == rhs.indented && lhs.isSelected == rhs.isSelected
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            selectionControl
            Image(systemName: item.isRestored ? "checkmark.circle" : item.kind.systemImage)
                .font(.system(size: 12))
                .foregroundColor(item.isRestored ? .secondary.opacity(0.6) : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundColor(item.isRestored ? .secondary : .primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "historyPane.row.delete", defaultValue: "Remove from History"))
            } else {
                Text(Self.relativeFormatter.localizedString(for: item.closedAt, relativeTo: Date()))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary.opacity(0.6))
                    .fixedSize()
            }
        }
        .padding(.leading, indented ? 24 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onReopen() }
        .help(item.menuSubtitle)
        .contextMenu {
            Button(action: onReopen) {
                Text(String(localized: "historyPane.row.reopen", defaultValue: "Reopen"))
            }
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(item.id.uuidString, forType: .string)
            } label: {
                Text(String(localized: "historyPane.row.copyId", defaultValue: "Copy ID"))
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Text(String(localized: "historyPane.row.delete", defaultValue: "Remove from History"))
            }
        }
    }

    @ViewBuilder
    private var selectionControl: some View {
        if item.isRestored {
            Image(systemName: "checkmark.square")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.45))
                .frame(width: 14)
        } else {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.75))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(String(localized: "historyPane.row.select", defaultValue: "Select for restore"))
        }
    }
}
