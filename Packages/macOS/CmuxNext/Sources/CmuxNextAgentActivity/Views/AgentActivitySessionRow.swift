import AppKit
import SwiftUI

struct AgentActivitySessionRow: View {
    @Environment(\.agentActivityColors) private var colors
    let session: AgentActivitySession
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            AgentActivityChip(hex: session.colorHex, live: session.status.isLive).padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.agentName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(AgentActivityFormat.relative(session.lastActionAt))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(colors.tertiary)
                }
                Text(session.label).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(colors.secondary)
                Text([session.workspaceTitle, session.terminalTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(colors.tertiary)
                HStack(spacing: 5) {
                    AgentActivityStatusPill(status: session.status)
                    if let badge = AgentActivityStrings.attribution(session.attribution) {
                        AgentActivityBadge(text: badge)
                    }
                    Spacer(minLength: 0)
                    AgentActivityCount(symbol: "cursorarrow.click", value: session.acts)
                    if session.errors > 0 {
                        AgentActivityCount(symbol: "exclamationmark.triangle", value: session.errors, tint: colors.danger)
                    }
                }
                Text(session.targetApps.joined(separator: ", "))
                    .font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(colors.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? colors.selection : .clear))
    }
}
