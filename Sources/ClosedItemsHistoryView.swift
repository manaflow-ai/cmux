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
    let store: ClosedItemHistoryStore
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
                    guard confirmClearAll() else { return }
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

    private func confirmClearAll() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "historyPane.clearAll.confirm.title", defaultValue: "Clear history?")
        alert.informativeText = String(
            localized: "historyPane.clearAll.confirm.message",
            defaultValue: "This removes all closed-item history. This cannot be undone."
        )
        alert.addButton(withTitle: String(localized: "historyPane.clearAll", defaultValue: "Clear All"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
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
