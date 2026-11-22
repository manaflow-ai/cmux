import Foundation
import Testing
@testable import CmuxNextAgentPane

/// While acpmux starts or restarts the pane shows nothing (Leo, 2026-10-29: "STOP SHOWING FUCKING
/// BULLSHIT ON LOAD"); only a refusal the page's retries cannot outlast is said at once.
struct AgentPaneHostErrorTransientTests {
    @Test func aDaemonStartingOrRestartingIsTransient() {
        let transient: [AgentPaneHostError] = [
            .timedOut, .daemonRestarting, .daemonStopped, .chiefStarting, .chiefStopped,
            .daemonFailed(logPath: "/l", cause: .exited),
            .daemonFailed(logPath: "/l", cause: .replacedBundle),
            .daemonFailed(logPath: "/l", cause: .peerRefused),
            .daemonFailed(logPath: "/l", cause: .noWebSocket),
            .daemonFailed(logPath: "/l", cause: .other),
            .daemonRefused(holder: nil, socketPath: "/s", reason: "the socket's peer process is unknown"),
        ]
        for error in transient { #expect(error.isTransient, "\(error)") }
    }

    @Test func aRefusalNothingRetriesAwayIsNot() {
        let owner = AcpmuxSocketOwner(path: "/Applications/cmux NIGHTLY.app/acpmux", socketPath: "/s")
        let refused: [AgentPaneHostError] = [
            .acpmuxNotFound,
            .daemonFailed(logPath: "/l", cause: .refused("its executable is in a temporary folder")),
            .daemonFailed(logPath: "/l", cause: .foreignHome),
            .daemonRefused(holder: "cmux NIGHTLY", socketPath: "/s", reason: "another build"),
            .daemonRefused(holder: nil, socketPath: "/s", reason: "another binary", owner: owner),
            // Another home's daemon whose pid is unavailable: no holder, still a refusal.
            .daemonRefused(holder: nil, socketPath: "/s",
                           reason: "\(AgentPaneHostError.foreignHomeReason)/Users/a/.acpmux, not /Users/a/.cmux-next/acpmux"),
        ]
        for error in refused { #expect(!error.isTransient, "\(error)") }
    }
}
