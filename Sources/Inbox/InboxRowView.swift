import CmuxFoundation
import CmuxInbox
import SwiftUI

struct InboxRowActions {
    let select: () -> Void
    let markRead: () -> Void
    let openOriginal: () -> Void
}

extension InboxSource {
    /// Accent tint used across inbox rows and badges.
    var tint: Color {
        switch self {
        case .agent: return Color.purple
        case .gmail: return Color.red
        case .slack: return Color.pink
        case .discord: return Color.indigo
        case .imessage: return Color.green
        case .generic: return Color.teal
        }
    }
}

struct InboxRowView: View {
    let row: InboxRowSnapshot
    let sourceLabel: String
    let ageLabel: String
    let isSelected: Bool
    let actions: InboxRowActions

    @State private var isHovering = false

    private var tint: Color { row.source.tint }

    var body: some View {
        Button(action: actions.select) {
            HStack(alignment: .top, spacing: 10) {
                sourceBadge

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.sender)
                            .cmuxFont(size: 12, weight: row.isUnread ? .semibold : .medium)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(ageLabel)
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .opacity(isHovering ? 0 : 1)
                    }

                    if row.title != row.sender, !row.title.isEmpty {
                        Text(row.title)
                            .cmuxFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(row.preview)
                        .cmuxFont(.caption)
                        .foregroundStyle(row.isUnread ? .primary : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 5) {
                        Text(sourceLabel)
                            .cmuxFont(size: 9.5, weight: .semibold)
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tint.opacity(0.12)))
                        if row.isActionable {
                            Label(String(localized: "inbox.row.actionable", defaultValue: "Actionable"), systemImage: "exclamationmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .cmuxFont(size: 9.5, weight: .semibold)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.orange.opacity(0.12)))
                        }
                    }
                    .padding(.top, 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { hoverActions }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(String(localized: "inbox.row.markRead", defaultValue: "Mark Read"), action: actions.markRead)
            if row.externalURL != nil {
                Button(String(localized: "inbox.row.openOriginal", defaultValue: "Open Original"), action: actions.openOriginal)
            }
        }
        .accessibilityIdentifier("InboxRow.\(row.itemID)")
    }

    private var sourceBadge: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(tint.opacity(row.isUnread ? 0.18 : 0.10))
                .frame(width: 26, height: 26)
            Image(systemName: row.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(row.isUnread ? tint : tint.opacity(0.7))
                .frame(width: 26, height: 26)
            if row.isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    .offset(x: 2, y: -2)
            }
        }
        .accessibilityHidden(true)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.14) : (isHovering ? Color.secondary.opacity(0.07) : Color.clear))
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var hoverActions: some View {
        if isHovering {
            HStack(spacing: 2) {
                Button(action: actions.markRead) {
                    Image(systemName: row.isUnread ? "envelope.open" : "envelope.badge")
                }
                .help(String(localized: "inbox.row.markRead", defaultValue: "Mark Read"))
                if row.externalURL != nil {
                    Button(action: actions.openOriginal) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help(String(localized: "inbox.row.openOriginal", defaultValue: "Open Original"))
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(.thinMaterial))
            .padding(.top, 6)
            .padding(.trailing, 12)
        }
    }
}

struct InboxFeedSectionHeaderView: View {
    let label: String

    var body: some View {
        Text(label)
            .cmuxFont(size: 10.5, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.4)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
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
