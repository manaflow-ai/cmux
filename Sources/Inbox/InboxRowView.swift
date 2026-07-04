import CmuxFoundation
import CmuxInbox
import SwiftUI

struct InboxRowActions {
    let select: () -> Void
    let markRead: () -> Void
    let openOriginal: () -> Void
}

struct InboxRowView: View {
    let row: InboxRowSnapshot
    let sourceLabel: String
    let ageLabel: String
    let isSelected: Bool
    let actions: InboxRowActions

    var body: some View {
        Button(action: actions.select) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: row.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(row.isUnread ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(row.sender)
                            .cmuxFont(size: 12, weight: row.isUnread ? .semibold : .medium)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(ageLabel)
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }

                    Text(row.title)
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(row.preview)
                        .cmuxFont(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(sourceLabel)
                            .cmuxFont(size: 10, weight: .medium)
                            .foregroundStyle(.secondary)
                        if row.isActionable {
                            Label(String(localized: "inbox.row.actionable", defaultValue: "Actionable"), systemImage: "exclamationmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .cmuxFont(size: 10, weight: .semibold)
                                .foregroundStyle(.orange)
                        } else if row.isUnread {
                            Label(String(localized: "inbox.row.unread", defaultValue: "Unread"), systemImage: "circle.fill")
                                .labelStyle(.titleAndIcon)
                                .cmuxFont(size: 10, weight: .semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: "inbox.row.markRead", defaultValue: "Mark Read"), action: actions.markRead)
            if row.externalURL != nil {
                Button(String(localized: "inbox.row.openOriginal", defaultValue: "Open Original"), action: actions.openOriginal)
            }
        }
        .accessibilityIdentifier("InboxRow.\(row.itemID)")
    }
}

struct InboxSourceChipView: View {
    let chip: InboxSourceChipSnapshot
    let label: String
    let statusLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: chip.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(label)
                    .cmuxFont(size: 11, weight: .medium)
                if chip.unreadCount > 0 {
                    Text("\(chip.unreadCount)")
                        .cmuxFont(size: 10, weight: .semibold)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                if statusLabel != nil, chip.status != .connected {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel(statusLabel ?? "")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(chip.isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        .help(statusLabel ?? label)
    }
}
