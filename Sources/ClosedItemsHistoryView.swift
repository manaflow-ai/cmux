import SwiftUI

/// Browses the closed-item history (closed terminals, browsers, panes, workspaces,
/// and windows) and lets the user reopen or forget any entry. This is the History
/// pane's content, distinct from the agent-session "Vault".
///
/// Follows the snapshot-boundary rule (https://github.com/manaflow-ai/cmux/issues/2586):
/// the store is observed only here; rows receive immutable ``ClosedItemHistoryMenuItem``
/// value snapshots plus closures, never the store itself.
struct ClosedItemsHistoryView: View {
    @ObservedObject var store: ClosedItemHistoryStore
    let onReopen: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onClearAll: () -> Void

    var body: some View {
        let snapshot = store.menuSnapshot(maxItemCount: nil)
        let onReopen = self.onReopen
        let onDelete = self.onDelete

        return VStack(spacing: 0) {
            header(count: snapshot.totalItemCount)
            if snapshot.items.isEmpty {
                emptyView
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.items) { item in
                            ClosedItemRow(
                                item: item,
                                onReopen: { onReopen(item.id) },
                                onDelete: { onDelete(item.id) }
                            )
                            .equatable()
                            .id(item.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .modifier(ClearScrollBackground())
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            Text(String(localized: "historyPane.header.recentlyClosed", defaultValue: "Recently Closed"))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
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
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
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

/// A single closed-item row. Value-snapshot + closures only; never observes the store.
private struct ClosedItemRow: View, Equatable {
    let item: ClosedItemHistoryMenuItem
    let onReopen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    static func == (lhs: ClosedItemRow, rhs: ClosedItemRow) -> Bool {
        lhs.item == rhs.item
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.92))
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
        .padding(.horizontal, 12)
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
            Divider()
            Button(role: .destructive, action: onDelete) {
                Text(String(localized: "historyPane.row.delete", defaultValue: "Remove from History"))
            }
        }
    }
}
