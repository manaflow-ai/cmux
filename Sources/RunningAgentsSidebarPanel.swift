import SwiftUI

struct RunningAgentsSidebarPanel: View {
    let rows: [RunningAgentSidebarItem]
    let onActivate: (RunningAgentSidebarItem) -> Void

    @State private var hoveredRowId: RunningAgentSidebarItem.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(localized: "sidebar.runningAgents.title", defaultValue: "Agents"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    Button {
                        onActivate(row)
                    } label: {
                        rowContent(row)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        hoveredRowId = isHovering ? row.id : (hoveredRowId == row.id ? nil : hoveredRowId)
                    }
                    .safeHelp(helpText(for: row))
                    .accessibilityIdentifier("SidebarRunningAgentRow.\(row.id)")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .accessibilityIdentifier("SidebarRunningAgentsPanel")
    }

    private func rowContent(_ row: RunningAgentSidebarItem) -> some View {
        HStack(alignment: .center, spacing: 7) {
            statusIcon(for: row)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.agentName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(row.statusText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(statusColor(for: row).opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(row.workspaceName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let latestNotificationText = row.latestNotificationText {
                    Text(latestNotificationText)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary.opacity(hoveredRowId == row.id ? 0.75 : 0.0))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(hoveredRowId == row.id ? Color.primary.opacity(0.07) : Color.clear)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusIcon(for row: RunningAgentSidebarItem) -> some View {
        if let icon = row.statusIcon?.trimmingCharacters(in: .whitespacesAndNewlines),
           !icon.isEmpty {
            explicitIcon(icon, color: statusColor(for: row))
        } else {
            Circle()
                .fill(statusColor(for: row))
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private func explicitIcon(_ icon: String, color: Color) -> some View {
        if icon.hasPrefix("emoji:") {
            Text(String(icon.dropFirst("emoji:".count)))
                .font(.system(size: 10))
        } else if icon.hasPrefix("text:") {
            Text(String(icon.dropFirst("text:".count)))
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(color)
        } else {
            let systemName = icon.hasPrefix("sf:") ? String(icon.dropFirst("sf:".count)) : icon
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
        }
    }

    private func statusColor(for row: RunningAgentSidebarItem) -> Color {
        if let raw = row.statusColor, let explicit = Color(hex: raw) {
            return explicit
        }
        switch row.lifecycleState {
        case .needsInput:
            return Color.orange
        case .running:
            return cmuxAccentColor()
        case .idle:
            return Color.secondary
        case .unknown:
            return Color.secondary.opacity(0.75)
        }
    }

    private func helpText(for row: RunningAgentSidebarItem) -> String {
        String(
            format: String(
                localized: "sidebar.runningAgents.row.help",
                defaultValue: "%1$@ in %2$@: %3$@"
            ),
            locale: .current,
            row.agentName,
            row.workspaceName,
            row.statusText
        )
    }
}
