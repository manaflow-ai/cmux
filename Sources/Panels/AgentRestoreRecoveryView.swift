import CMUXAgentLaunch
import SwiftUI

/// Displays recovery state outside the terminal input stream.
struct AgentRestoreRecoveryView: View {
    let state: AgentRestoreRecoveryPresentation.State

    var body: some View {
        let showsProgress: Bool = switch state {
        case .checking, .writerLock:
            true
        case .liveOwner, .parkedTranscriptUnavailable, .parkedResumeUnavailable:
            false
        }
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            }
            Text(message).font(.callout).textSelection(.enabled)
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
        case .liveOwner(let kind, let processID):
            String(
                format: String(
                    localized: "agentRestore.recovery.liveOwner",
                    defaultValue: "%1$@ session is running in process %2$@. Waiting for its writer to become available…"
                ),
                locale: Locale(identifier: "en_US_POSIX"),
                kind,
                String(processID)
            )
        case .parkedTranscriptUnavailable:
            String(localized: "sessionIndex.preview.noFile", defaultValue: "No transcript file")
        case .parkedResumeUnavailable:
            String(localized: "sessionIndex.preview.error", defaultValue: "Couldn't load transcript")
        }
    }
}
