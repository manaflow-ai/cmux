public import CmuxNextAgentPane
import Foundation
import os

/// Heals a Chief chat that cannot reach the Chief home's acpmux because that
/// daemon runs an old version an update replaced (2026-10-18: the NIGHTLY
/// update left daemon 8886 on the deleted binary, and every Chief chat said
/// "acpmux did not start" until a manual restart).
///
/// The heal is the same path a relaunch takes (`HomeBrainHost.start`), run
/// while the app runs: the stale daemon is handed off (`_acpmux/shutdown`; its
/// agent hosts keep running and the next daemon adopts them), the Chief host
/// that ran on it is stopped, and the brain keeper's watch starts the host
/// again, which starts the bundled acpmux. A tab still never starts that
/// daemon itself (cx-ebm.54).
public nonisolated struct ChiefAcpmuxHeal: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    let home: ChiefHome
    let environment: AcpmuxEnvironment
    /// Starts the brain host when none runs (`ChiefBrainKeeper.ensure`), after the stop.
    let ensureHost: @Sendable () async -> Void

    /// - Parameters:
    ///   - home: the Chief home whose acpmux the chat uses.
    ///   - environment: that home's acpmux environment (`ChiefHome.acpmuxHome`).
    ///   - ensureHost: starts the Chief host again when its watch did not.
    public init(home: ChiefHome, environment: AcpmuxEnvironment, ensureHost: @escaping @Sendable () async -> Void) {
        self.home = home
        self.environment = environment
        self.ensureHost = ensureHost
    }

    /// Hands off the stale daemon and restarts the Chief host. Returns whether
    /// it handed one off; false leaves everything as it was.
    @concurrent public func heal() async -> Bool {
        let handoff = AcpmuxChiefHandoff(environment: environment, chiefMuxHome: home.muxHome.path)
        guard await handoff.handOffReplaced() else { return false }
        if let pid = await ChiefHostStop.stop(home: home) {
            Self.logger.info("Chief host \(pid) stopped after its acpmux handoff; the brain watch starts it again")
            _ = await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
        }
        await ensureHost()
        return true
    }
}
