import SwiftUI

/// Snapshot-only row for one terminal or recognized coding agent in Herd.
struct HerdLaneRow: View {
    let lane: HerdPanelSnapshot.Lane
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                statusGlyph

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(lane.agentKey.map(displayAgentName) ?? lane.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        if lane.isFocused {
                            Image(systemName: "scope")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("\(lane.workspaceTitle)  ·  \(lane.title)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Text(statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("HerdLaneRow-\(lane.panelID.uuidString)")
        .accessibilityLabel("\(lane.agentKey.map(displayAgentName) ?? lane.title), \(lane.workspaceTitle), \(statusLabel)")
    }

    private var statusGlyph: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.16))
                .frame(width: 26, height: 26)
            Image(systemName: statusSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
        }
    }

    private var statusSymbol: String {
        switch lane.lifecycle {
        case .needsInput: "exclamationmark.bubble.fill"
        case .working: "bolt.fill"
        case .idle: "checkmark"
        case .unknown: "questionmark"
        case .terminal: "terminal.fill"
        }
    }

    private var statusColor: Color {
        switch lane.lifecycle {
        case .needsInput: .orange
        case .working: .blue
        case .idle: .green
        case .unknown: .secondary
        case .terminal: .secondary
        }
    }

    private var statusLabel: String {
        switch lane.lifecycle {
        case .needsInput:
            String(localized: "feed.status.needsInput", defaultValue: "Needs input")
        case .working:
            String(localized: "agent.generic.status.running", defaultValue: "Running")
        case .idle:
            String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle")
        case .unknown:
            String(localized: "taskManager.row.surfaceType.unknown", defaultValue: "Unknown")
        case .terminal:
            String(localized: "taskManager.row.surfaceType.terminal", defaultValue: "Terminal")
        }
    }

    private func displayAgentName(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
