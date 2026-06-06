import AppKit
import Foundation
import SwiftUI

/// A single closed-item row. Value-snapshot + closures only; never observes the store.
struct ClosedItemRow: View, Equatable {
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
