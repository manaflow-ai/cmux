public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextWakeups
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
/// that ran on it is stopped (or, when it takes that, asked to hand off when its
/// turn ends, so the heal never cuts a Chief turn), and the brain keeper's watch
/// starts the host again, which starts the bundled acpmux. A tab still never starts that
/// daemon itself (cx-ebm.54).
public nonisolated struct ChiefAcpmuxHeal: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    let home: ChiefHome
    let environment: AcpmuxEnvironment
    /// Starts the brain host when none runs (`ChiefBrainKeeper.ensure`), after the stop.
    let ensureHost: @Sendable () async -> Void
    /// Runs the follow-up that waits for a busy Chief host's turn to end.
    let work: BackgroundWork

    /// - Parameters:
    ///   - home: the Chief home whose acpmux the chat uses.
    ///   - environment: that home's acpmux environment (`ChiefHome.acpmuxHome`).
    ///   - work: the app's background work, which runs the follow-up after a busy host's turn.
    ///   - ensureHost: starts the Chief host again when its watch did not.
    public init(home: ChiefHome, environment: AcpmuxEnvironment, work: BackgroundWork,
                ensureHost: @escaping @Sendable () async -> Void) {
        self.home = home
        self.environment = environment
        self.work = work
        self.ensureHost = ensureHost
    }

    /// Hands off the stale daemon and restarts the Chief host. Returns whether
    /// it handed one off now; false leaves the daemon running (the Chief host may
    /// have been asked to hand off when its turn ends: then the heal finishes after that).
    @concurrent public func heal() async -> Bool {
        let handoff = AcpmuxChiefHandoff(environment: environment, chiefMuxHome: home.muxHome.path)
        // An update never cuts a Chief turn: a host that takes it hands off when its turn ends,
        // and the heal finishes after it exits. Only an older host is stopped here.
        let home = home
        // The host that took the signal, not one read before it: a host that starts in between
        // would otherwise be stopped mid-turn when the one read earlier is already gone.
        let asked = Mutex<pid_t?>(nil)
        switch await handoff.handOffReplaced(waitFor: {
            let pid = ChiefHostStop.askToHandOffWhenIdle(home: home)
            asked.withLock { $0 = pid }
            return pid != nil
        }) {
        case .keep:
            return false
        case .waitForHost:
            let ensureHost = ensureHost
            let host = asked.withLock { $0 }
            // task-owner: one follow-up per stale daemon (the pane heals each pid once); it ends
            // when the host exits, however long its turn runs (one exit source, no timer). Nobody
            // waits for it (best effort); quit cancels it and the next launch's HomeBrainHost.start heals.
            work.task(.bestEffort) {
                await Self.finishAfterTurn(
                    hostExited: {
                        guard let host else { return true }
                        return await AgentPaneProcessExit(pid: host).event(within: nil)
                    },
                    handOff: { await handoff.handOffReplaced(waitFor: { false }) == .handOff },
                    stopHost: { await Self.stopHost(home: home) },
                    ensureHost: ensureHost)
            }
            return false
        case .handOff:
            await Self.stopHost(home: home)
            await ensureHost()
            return true
        }
    }

    /// After the Chief host that was asked to hand off when idle exits: hands the replaced
    /// daemon off here, not through `HomeBrainHost.start` (its handoff runs once per Chief
    /// home per app run, so a second update in one run would leave the daemon in place), stops
    /// a host the brain watch started on it meanwhile, and starts the host again, which the
    /// brain watch may not do (no watch, or its restart limit). A host that never exits leaves
    /// everything as it is.
    static func finishAfterTurn(hostExited: () async -> Bool, handOff: () async -> Bool,
                                stopHost: () async -> Void, ensureHost: () async -> Void) async {
        guard await hostExited() else {
            logger.error("Chief host did not end its turn in time; its acpmux keeps running from a replaced bundle")
            return
        }
        if await handOff() {
            logger.info("Chief acpmux handed off after the Chief host's turn ended")
            await stopHost()
        }
        await ensureHost()
    }

    /// Stops the Chief host that ran on a daemon just handed off, and waits for it to exit.
    @concurrent static func stopHost(home: ChiefHome) async {
        guard let pid = await ChiefHostStop.stop(home: home) else { return }
        logger.info("Chief host \(pid) stopped after its acpmux handoff; the brain watch starts it again")
        _ = await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
    }
}
