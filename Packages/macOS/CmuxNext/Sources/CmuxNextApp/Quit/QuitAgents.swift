import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import os

/// The local acpmux daemon at quit (plans/cmux-next/quit-persistence.md
/// 4.3): an End quit's end of every agent except the Home Chief's.
@MainActor
enum QuitAgents {
    /// The acpmux this app starts (its build's home), or nil when the app runs
    /// a mock agent host or has no acpmux binary. A DEV build with
    /// `CMUX_NEXT_ACPMUX_ATTACH` gets that home's daemon instead, attached (never its own).
    static func environment(_ services: AppServices) -> AcpmuxEnvironment? {
        AcpmuxEnvironment.app(build: services.environment.build, mock: services.environment.showcase)
    }

    /// Whether `environment` is attached to the daemon of `home`.
    static func isAttached(_ environment: AcpmuxEnvironment?, to home: URL) -> Bool {
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        guard let environment, environment.isAttached else { return false }
        return canonical(environment.home) == canonical(home)
    }

    /// The quit's view of one end: only proof is success (an ended
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
    /// `keep`: the Home Chief's sessions, unless the Chief runs on this daemon
    /// (``ChiefHostStop/appAcpmuxEndKeep(chiefUsesAppAcpmux:)``).
    static func end(_ environment: AcpmuxEnvironment?, keep: AcpmuxQuit.Keep = .chief,
                    waitForShutdown: Bool = false) async -> [EndSessionsFailure] {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
        if environment?.isAttached == true { logger.info("end agents: skipped, attached to \(environment?.home.path ?? "", privacy: .public)"); return [] }
        let result = await AcpmuxQuit.endAgents(environment, keep: keep, waitForShutdown: waitForShutdown)
        logger.info("end agents: \(String(describing: result), privacy: .public)")
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
