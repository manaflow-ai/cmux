#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Snapshot-only row that starts a one-tap live-session handoff.
struct RegistryLiveSessionRow: View {
    let session: RegistryLiveSessionSnapshot
    let isConnecting: Bool
    let continueSession: () -> Void

    var body: some View {
        Button(action: continueSession) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title3)
                    .foregroundStyle(statusTint)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.workspaceTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(session.deviceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(agentLabel)
                        Text("·").accessibilityHidden(true)
                        Text(statusLabel)
                        Text("·").accessibilityHidden(true)
                        Text(session.lastActivityAt, format: .relative(presentation: .named))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("MobileLiveSession-\(session.id)")
    }

    private var agentLabel: String {
        guard let agent = session.agent, !agent.isEmpty else {
            return L10n.string("mobile.handoff.agent.terminal", defaultValue: "Terminal")
        }
        return agent.capitalized
    }

    private var statusLabel: String {
        switch session.status {
        case .working:
            return L10n.string("mobile.handoff.status.working", defaultValue: "Working")
        case .needsInput:
            return L10n.string("mobile.handoff.status.needsInput", defaultValue: "Needs input")
        case .idle:
            return L10n.string("mobile.handoff.status.idle", defaultValue: "Ready")
        case .ended:
            return L10n.string("mobile.handoff.status.ended", defaultValue: "Agent ended")
        }
    }

    private var statusSymbol: String {
        switch session.status {
        case .working: return "sparkles"
        case .needsInput: return "exclamationmark.bubble.fill"
        case .idle: return "terminal.fill"
        case .ended: return "terminal"
        }
    }

    private var statusTint: Color {
        switch session.status {
        case .working: return .blue
        case .needsInput: return .orange
        case .idle: return .green
        case .ended: return .secondary
        }
    }

    private var accessibilityLabel: String {
        String(
            format: L10n.string(
                "mobile.handoff.session.accessibilityFormat",
                defaultValue: "%1$@ on %2$@, %3$@, %4$@"
            ),
            session.workspaceTitle,
            session.deviceTitle,
            agentLabel,
            statusLabel
        )
    }
}
#endif
