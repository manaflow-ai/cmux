import CmuxAgentSync
@testable import CmuxAgentGUIUI
import Testing

@Suite
struct TranscriptSyncPresentationTests {
    @Test(arguments: [
        (AgentConnectivityPhase.updating, 0, false, TranscriptSyncPresentation.loading),
        (.connecting(backoffMilliseconds: 500), 1, false, .loading),
        (.connecting(backoffMilliseconds: 500), 2, false, .error),
        (.connecting(backoffMilliseconds: 500), 2, true, .stale),
        (.connected, 0, false, .hidden),
        (.connected, 0, true, .hidden),
    ])
    func presentationTable(
        phase: AgentConnectivityPhase,
        failures: Int,
        hasContent: Bool,
        expected: TranscriptSyncPresentation
    ) {
        #expect(TranscriptSyncPresentation(
            phase: phase,
            consecutiveFailures: failures,
            hasContent: hasContent
        ) == expected)
    }
}
