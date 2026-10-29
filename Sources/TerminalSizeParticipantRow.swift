import Bonsplit
import CmuxTerminalSharing
import CmuxTerminalSizing
import SwiftUI

/// One participant row of the size panel: a neutral avatar
/// (``TerminalSizingChromeColor/panelColor(_:)``), name, `sets size`
/// for the owner or `not counted` for an ignored row, and on hover a "…" menu
/// with Counts toward size and Disconnect.
/// In priority mode a leading drag handle shows the row can be reordered.
struct TerminalSizeParticipantRow: View {
    let row: TerminalSizingParticipantState
    let initials: String
    let label: String
    let isOwner: Bool
    let statusLabel: String?
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
            if let statusLabel {
                Text(statusLabel)
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
            .fill(TerminalSizingChromeColor.panelColor(.fill))
            .frame(width: 18, height: 18)
            .overlay(
                Text(verbatim: initials)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(TerminalSizingChromeColor.panelColor(.glyph))
            )
            .overlay {
                if isOwner {
                    Circle()
                        .inset(by: -1.5)
                        .stroke(TerminalSizingChromeColor.panelColor(.line), lineWidth: 1)
                }
            }
            // Full opacity even when not counted: dimming would break the
            // initials' 4.5:1 contrast; the row's status label says it.
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
