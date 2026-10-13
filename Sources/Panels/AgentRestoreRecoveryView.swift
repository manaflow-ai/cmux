import CMUXAgentLaunch
import SwiftUI

/// Displays recovery state outside the terminal input stream.
struct AgentRestoreRecoveryView: View {
    let state: AgentRestoreRecoveryPresentation.State
    let onAttach: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message).font(.callout).textSelection(.enabled)
            if case .liveOwner(_, _, let attachInput, let attachAvailable) = state,
               attachAvailable,
               let attachInput {
                Button(String(localized: "agentRestore.recovery.attach", defaultValue: "Attach")) { onAttach(attachInput) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .accessibilityIdentifier("agent-restore-recovery")
    }

    private var message: String {
        switch state {
        case .checking:
            String(localized: "agentRestore.recovery.checking", defaultValue: "Restoring saved agent session…")
        case .writerLock(let candidates):
            CodexWriterRestoreNotice().message(candidates: candidates)
        case .liveOwner(let kind, let processID, _, _):
            String(
                format: String(
                    localized: "agentRestore.recovery.liveOwner",
                    defaultValue: "%1$@ session is running in process %2$@. Waiting for its writer to become available…"
                ),
                locale: Locale(identifier: "en_US_POSIX"),
                kind,
                String(processID)
            )
        }
    }
}
