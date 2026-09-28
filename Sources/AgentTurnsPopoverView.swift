import AppKit
import SwiftUI

/// Per-pane turn timeline: the running agent session's prompts and
/// checkpoints, with Stop, Edit (put a past prompt back in the input), and
/// Fork (a new workspace from just before that prompt).
struct AgentTurnsPopoverView: View {
    let agentName: String
    let entry: SessionEntry?
    let isRunning: Bool
    let onStop: () -> Void
    let onEditPrompt: (String) -> Void
    let onResume: (SessionEntry) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(entry?.title ?? agentName)
                    .cmuxFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if isRunning {
                    Button(action: onStop) {
                        Label(
                            String(localized: "terminal.agentTurnControl.stop", defaultValue: "Stop"),
                            systemImage: "stop.fill"
                        )
                        .cmuxFont(size: 11, weight: .semibold)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("AgentTurnsStopButton")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let entry {
                VaultCheckpointTimelineView(
                    entry: entry,
                    onResume: onResume,
                    onDismiss: onDismiss,
                    onEditPrompt: onEditPrompt
                )
            } else {
                Text(String(
                    localized: "terminal.agentTurns.noSession",
                    defaultValue: "This agent's session isn't in the Vault yet. Turns appear after its first prompt."
                ))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
            }
        }
        .frame(width: 420, height: entry == nil ? 90 : 440, alignment: .topLeading)
    }
}
