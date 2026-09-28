import CmuxTerminalSharing
import CmuxTerminalSizing
import SwiftUI

/// One participant row of the size panel.
struct TerminalSizeParticipantRow: View {
    let row: TerminalSizingParticipantState
    let label: String
    let isSelf: Bool
    let setsSize: Bool
    let priorityIndex: Int?
    let onCountsChange: (Bool) -> Void
    let onMoveUp: (() -> Void)?
    let onDisconnect: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let priorityIndex {
                Text(verbatim: "\(priorityIndex)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            Circle()
                .fill(TerminalSharingDisplay.color(for: row.participant))
                .frame(width: 22, height: 22)
                .overlay(
                    Text(TerminalSharingDisplay.initials(for: row.participant))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.8))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(label).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if setsSize {
                badge(String(localized: "terminalSharing.panel.badge.setsSize", defaultValue: "Sets size"))
            } else if !row.counts {
                badge(String(localized: "terminalSharing.panel.badge.viewer", defaultValue: "Viewer"))
            }
            if let onMoveUp {
                Button(action: onMoveUp) { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "terminalSharing.panel.moveUp", defaultValue: "Move Up in Priority"))
            }
            if let onDisconnect {
                Button(action: onDisconnect) { Image(systemName: "eject") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "terminalSharing.panel.disconnect", defaultValue: "Disconnect"))
                    .accessibilityLabel(String(
                        format: String(localized: "terminalSharing.panel.disconnect.accessibility", defaultValue: "Disconnect %@"),
                        label
                    ))
            }
            Toggle(isOn: Binding(get: { row.counts }, set: onCountsChange)) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(String(localized: "terminalSharing.panel.counts", defaultValue: "Counts toward size"))
                .accessibilityLabel(String(
                    format: String(localized: "terminalSharing.panel.counts.accessibility", defaultValue: "%@ counts toward size"),
                    label
                ))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var detail: String {
        let device = TerminalSharingDisplay.deviceKindLabel(row.participant.deviceKind)
        guard let viewport = row.participant.viewport else { return device }
        return "\(device) · \(TerminalSharingDisplay.compactGridLabel(viewport))"
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(TerminalSharingDisplay.color(for: row.participant)))
    }
}
