import AppKit
import SwiftUI

/// Browses the closed-item history (closed terminals, browsers, panes, workspaces,
/// and windows) grouped by destructive operation, and lets the user reopen or
/// forget any entry. This is the History pane's content, distinct from the
/// agent-session "Vault".
///
/// Each destructive action is one operation (a single close, or a multi-select
/// delete of N items). Operations render as collapsible groups: "Restore all" on
/// the header brings back the items that are not already restored, and each child
/// can be reopened or removed individually.
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

    var body: some View {
        let operations = store.operationSnapshot()
        let totalItems = operations.reduce(0) { $0 + $1.items.count }
        let onReopen = self.onReopen
        let onDelete = self.onDelete
        let restorableWorkspaceIds = operations
            .flatMap(\.items)
            .filter { $0.kind == .workspace && !$0.isRestored }
            .map(\.id)

        return VStack(spacing: 0) {
            header(count: totalItems, restorableWorkspaceIds: restorableWorkspaceIds)
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
                                onRestoreAll: {
                                    for item in op.items where !item.isRestored {
                                        onReopen(item.id)
                                    }
                                }
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

    private func header(count: Int, restorableWorkspaceIds: [UUID]) -> some View {
        let onReopen = self.onReopen
        return HStack(spacing: 8) {
            Text(String(localized: "historyPane.header.recentlyClosed", defaultValue: "Recently Closed"))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            if !restorableWorkspaceIds.isEmpty {
                Button {
                    for id in restorableWorkspaceIds { onReopen(id) }
                } label: {
                    Text(String(localized: "historyPane.reopenAllWorkspaces", defaultValue: "Reopen all workspaces"))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "historyPane.reopenAllWorkspaces.tooltip", defaultValue: "Reopen every closed workspace that isn't already open"))
            }
            if count > 0 {
                Button(action: onClearAll) {
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
    let onRestoreAll: () -> Void

    static func == (lhs: ClosedOperationGroup, rhs: ClosedOperationGroup) -> Bool {
        lhs.operation == rhs.operation && lhs.isCollapsed == rhs.isCollapsed
    }

    var body: some View {
        if operation.isSingleton, let item = operation.items.first {
            ClosedItemRow(
                item: item,
                indented: false,
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
            Image(systemName: "rectangle.stack")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(operation.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(operation.isFullyRestored ? .secondary : .primary.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 8)
            if !operation.isFullyRestored {
                Button(action: onRestoreAll) {
                    Text(String(localized: "historyPane.group.restoreAll", defaultValue: "Restore all"))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "historyPane.group.restoreAll.tooltip", defaultValue: "Reopen the items in this group that aren't already open"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { onToggleCollapse() }
    }
}

/// A single closed-item row. Value-snapshot + closures only; never observes the store.
private struct ClosedItemRow: View, Equatable {
    let item: ClosedItemHistoryMenuItem
    let indented: Bool
    let onReopen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    static func == (lhs: ClosedItemRow, rhs: ClosedItemRow) -> Bool {
        lhs.item == rhs.item && lhs.indented == rhs.indented
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
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
        .padding(.leading, indented ? 30 : 12)
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
}
