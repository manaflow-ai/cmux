import CmuxTerminalSharing
import CmuxTerminalSizing
import SwiftUI

/// One participant row of the size panel: avatar, name, "sets size" for the
/// owner, and on hover a "…" menu with Counts toward size and Disconnect.
/// In priority mode a leading drag handle shows the row can be reordered.
struct TerminalSizeParticipantRow: View {
    let row: TerminalSizingParticipantState
    let initials: String
    let label: String
    let setsSize: Bool
    let showsDragHandle: Bool
    let onCountsChange: (Bool) -> Void
    let onDisconnect: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            avatar
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.counts ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
            Spacer(minLength: 4)
            if setsSize {
                Text(String(localized: "terminalSharing.panel.setsSize", defaultValue: "sets size"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            optionsMenu
                .opacity(isHovered ? 1 : 0)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var avatar: some View {
        Circle()
            .fill(TerminalSharingDisplay.color(for: row.participant))
            .frame(width: 18, height: 18)
            .overlay(
                Text(verbatim: initials)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
            )
            .opacity(row.counts ? 1 : 0.55)
            .accessibilityHidden(true)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(
                String(localized: "terminalSharing.panel.counts", defaultValue: "Counts toward size"),
                isOn: Binding(get: { row.counts }, set: onCountsChange)
            )
            if let onDisconnect {
                Divider()
                Button(String(localized: "terminalSharing.panel.disconnect", defaultValue: "Disconnect"), role: .destructive) {
                    onDisconnect()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(
            format: String(localized: "terminalSharing.panel.rowOptions", defaultValue: "Options for %@"),
            label
        ))
    }
}
