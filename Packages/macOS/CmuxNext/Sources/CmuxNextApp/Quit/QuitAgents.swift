import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import os

/// The local acpmux daemon at quit (plans/cmux-next/quit-persistence.md
/// 4.1, 4.3): one census when the quit dialog opens (1 s, never polled),
/// and Quit Everything's end of every agent except the Home Chief's.
@MainActor
enum QuitAgents {
    /// The acpmux this app starts (same tag home), or nil when the app runs
    /// a mock agent host or has no acpmux binary.
    static func environment(_ services: AppServices) -> AcpmuxEnvironment? {
        let variables = ProcessInfo.processInfo.environment
        if services.environment.showcase || variables["CMUX_NEXT_AGENT_PANE_MOCK"] == "1" { return nil }
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        return AcpmuxEnvironment.resolve(tag: services.environment.tag, bundledBinDirectory: bin, environment: variables)
    }

    /// Nil when acpmux did not answer in time (unknown, not zero).
    static func facts(_ environment: AcpmuxEnvironment?) async -> QuitAgentFacts? {
        guard let census = await AcpmuxQuit.census(environment, deadline: QuitFactsReader.deadline) else { return nil }
        return QuitAgentFacts(live: census.live, inTurn: census.inTurn, inTurnNames: census.inTurnNames,
                              chiefInTurn: census.chiefInTurn)
    }

    /// The quit dialog's view of one end: only proof is success (an ended
    /// daemon, or no daemon and no agent host left). A shutdown in progress
    /// or agents still running is the error state ("agents may still be
    /// running") with Retry and Quit Anyway; the app never claims that
    /// agents ended without proof.
    static func failures(for result: AcpmuxQuit.EndResult) -> [EndSessionsFailure] {
        switch result {
        case .noDaemon, .ended: []
        case .failed(let reason): [EndSessionsFailure(step: .endAgents, message: reason)]
        case .shutdownInProgress: [EndSessionsFailure(step: .endAgents, message: QuitStrings.agentsShutdownInProgress)]
        case .agentsStillRunning(let sessions): [EndSessionsFailure(step: .endAgents, message: QuitStrings.agentsStillRunning(sessions.count))]
        }
    }

    /// Ends the local agents. A failure is returned, so the quit shows it
    /// with Retry and Quit Anyway; agents that did not end keep running.
    /// `waitForShutdown` (a Retry) waits for a shutdown already in progress.
    static func end(_ environment: AcpmuxEnvironment?, waitForShutdown: Bool = false) async -> [EndSessionsFailure] {
        let result = await AcpmuxQuit.endAgents(environment, waitForShutdown: waitForShutdown)
        Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
            .info("end agents: \(String(describing: result), privacy: .public)")
        return failures(for: result)
    }
}

/// Counts the end attempts of one quit: the first does not wait for a
/// shutdown already in progress, every Retry does.
@MainActor
final class QuitAttempts {
    private var count = 0

    /// True from the second attempt on.
    func isRetry() -> Bool {
        defer { count += 1 }
        return count > 0
    }
}
