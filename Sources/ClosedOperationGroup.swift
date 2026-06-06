import Foundation
import SwiftUI

/// Renders one operation: a single row for a singleton close, or a collapsible
/// group header plus child rows for a multi-item operation.
struct ClosedOperationGroup: View, Equatable {
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
