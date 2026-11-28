import AppKit
import SwiftUI

/// The session's cursor color; a ring when the session is live.
struct AgentActivityChip: View {
    let hex: String
    let live: Bool

    var body: some View {
        Circle()
            .fill(AgentActivityColor.color(hex: hex))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(AgentActivityColor.color(hex: hex).opacity(live ? 0.35 : 0), lineWidth: 3).padding(-2.5))
    }
}

struct AgentActivityStatusPill: View {
    @Environment(\.agentActivityColors) private var colors
    let status: AgentActivityStatus

    var body: some View {
        Text(AgentActivityStrings.status(status))
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(fill))
            .foregroundStyle(foreground)
    }

    private var fill: Color {
        switch status {
        case .active: colors.success.opacity(0.16)
        case .paused: colors.attention.opacity(0.18)
        case .idle, .ended: colors.badge
        }
    }

    private var foreground: Color {
        switch status {
        case .active: colors.success
        case .paused: colors.attention
        case .ended(.userStop): colors.danger
        case .idle, .ended: colors.secondary
        }
    }
}

struct AgentActivityBadge: View {
    @Environment(\.agentActivityColors) private var colors
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(tint.map { $0.opacity(0.16) } ?? colors.badge))
            .foregroundStyle(tint ?? colors.secondary)
    }
}
