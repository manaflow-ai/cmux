import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The quit dialog's error state for agents (R96 + P2-9): only proof of an
/// ended daemon with no agent host left, or no daemon and no host, is
/// success; a shutdown in progress or agents still running is an
/// "agents may still be running" failure with Retry and Quit Anyway.
@MainActor
struct QuitAgentsMappingTests {
    @Test func onlyProofIsSuccess() {
        #expect(QuitAgents.failures(for: .ended).isEmpty)
        #expect(QuitAgents.failures(for: .noDaemon).isEmpty)
    }

    @Test func aShutdownInProgressIsTheErrorState() {
        let failures = QuitAgents.failures(for: .shutdownInProgress(pid: 42))
        #expect(failures == [EndSessionsFailure(step: .endAgents, message: QuitStrings.agentsShutdownInProgress)])
        #expect(QuitFailureContent.line(failures[0]).contains(QuitStrings.agentsShutdownInProgress))
    }

    @Test func agentsStillRunningIsTheErrorState() {
        let failures = QuitAgents.failures(for: .agentsStillRunning(["a", "b"]))
        #expect(failures == [EndSessionsFailure(step: .endAgents, message: QuitStrings.agentsStillRunning(2))])
    }

    @Test func aFailureKeepsItsReason() {
        #expect(QuitAgents.failures(for: .failed("refused")) == [EndSessionsFailure(step: .endAgents, message: "refused")])
    }
}
