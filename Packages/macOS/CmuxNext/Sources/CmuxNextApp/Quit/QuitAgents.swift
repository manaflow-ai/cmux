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

    /// Ends the local agents. A failure is returned, so the quit shows it
    /// with Retry and Quit Anyway; agents that did not end keep running.
    static func end(_ environment: AcpmuxEnvironment?) async -> [EndSessionsFailure] {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
        switch await AcpmuxQuit.endAgents(environment) {
        case .noDaemon:
            logger.info("end agents: no acpmux running")
            return []
        case .ended:
            logger.info("end agents: acpmux ended its agents and stopped")
            return []
        case .failed(let reason):
            logger.error("end agents failed: \(reason, privacy: .public)")
            return [EndSessionsFailure(step: .endAgents, message: reason)]
        }
    }
}
