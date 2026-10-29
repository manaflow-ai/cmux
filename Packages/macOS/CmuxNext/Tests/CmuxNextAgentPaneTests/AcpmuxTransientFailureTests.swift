import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A daemon in the middle of a restart is said in the pane's header, not its card, and a stale
/// daemon that refuses its handoff never holds the socket (cosmic-gray, 2026-10-29).
struct AcpmuxTransientFailureTests {
    @Test func restartFailuresAreTransient() {
        #expect(AgentPaneHostError.timedOut.isTransient)
        #expect(AgentPaneHostError.daemonRestarting.isTransient)
        #expect(AgentPaneHostError.chiefStarting.isTransient)
        #expect(AgentPaneHostError.daemonFailed(logPath: "/l", cause: .exited).isTransient)
        #expect(AgentPaneHostError.daemonRefused(holder: nil, socketPath: "/s", reason: "the socket's peer process is unknown").isTransient)
    }

    @Test func failuresThatNeedThePersonAreNot() {
        #expect(!AgentPaneHostError.acpmuxNotFound.isTransient)
        #expect(!AgentPaneHostError.daemonStopped.isTransient)
        #expect(!AgentPaneHostError.chiefStopped.isTransient)
        #expect(!AgentPaneHostError.daemonFailed(logPath: "/l", cause: .noWebSocket).isTransient)
        #expect(!AgentPaneHostError.daemonRefused(holder: "cmux DEV x", socketPath: "/s", reason: "other").isTransient)
    }

    @Test func aReplacedDaemonThatRefusesItsHandoffIsStopped() {
        #expect(AcpmuxVersionHandoff.afterRefusal(replaced: true, attached: false) == .signal)
        // An attached daemon is never stopped by this app; a live install's daemon is asked again later.
        #expect(AcpmuxVersionHandoff.afterRefusal(replaced: true, attached: true) == .askAgain)
        #expect(AcpmuxVersionHandoff.afterRefusal(replaced: false, attached: false) == .askAgain)
    }
}
