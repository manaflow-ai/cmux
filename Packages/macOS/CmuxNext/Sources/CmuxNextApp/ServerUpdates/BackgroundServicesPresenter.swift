import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextUpdater
import os

/// Restart Background Services… (Cmd+Shift+P, `cmux settings restart-background-services`, cmux
/// issue 23089): shows the running and bundled build of every background service this app runs
/// (its cmux-tui session owner, the Chief's cmux-tui owner, its acpmux and the Chief's acpmux),
/// asks, then moves each one to the bundled build by the handoff an update uses, so terminals and
/// agent sessions keep running. It never restarts anything without the confirm.
@MainActor
final class BackgroundServicesPresenter {
    private weak var services: AppServices?
    /// A confirm or restart runs: a second ask waits for it to end.
    private var busy = false
    /// The app acpmux restart that waits for the Chief's turn to end (NIGHTLY); one at a time.
    private var afterTurnRestart: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "background-services")

    init(services: AppServices) {
        self.services = services
    }

    func start(registry: ActionRegistry) {
        registry.bind("palette.restartBackgroundServices", run: { [weak self] _ in self?.confirm() })
    }

    /// Reads every service's builds, then shows the confirm on the active window.
    func confirm() {
        guard !busy, let window = services?.windows.active?.window else { return }
        busy = true
        // task-owner: one confirm per ask; `busy` keeps a second one out until it ends
        Task { @MainActor [weak self] in
            guard let self, let report = await self.report() else {
                self?.busy = false
                return
            }
            _ = CmuxDialogCenter.shared.present(report.confirmSpec, in: .window(window)) { [weak self] answer in
                guard let self else { return }
                guard answer.button == "restart" else {
                    self.busy = false
                    return
                }
                // task-owner: the confirmed restart; its toast reports the end
                Task { @MainActor in
                    let result = await self.restart(report)
                    self.busy = false
                    let toast = CmuxToast(id: "background-services.result", message: result.message)
                    if let window = self.services?.windows.active?.window { CmuxToastCenter.shared.show(toast, in: window) }
                }
            }
        }
    }

    /// The running and bundled build of each service.
    func report() async -> BackgroundServicesReport? {
        guard let services else { return nil }
        let bundledTUI = await services.daemon.bundledBuildCommit?()
        var list = [BackgroundService(role: .sessionOwner, running: services.daemon.identity?.buildCommit, bundled: bundledTUI)]
        let chief = services.home.chief
        if chief.isRunning {
            list.append(BackgroundService(role: .chiefOwner, running: chief.identity?.buildCommit, bundled: bundledTUI))
        }
        if let host = services.agentTabs.host as? AcpmuxHost, let builds = await host.serviceBuilds() {
            list.append(BackgroundService(role: .agents, running: builds.running, bundled: builds.bundled,
                                          skip: builds.keepsAgents ? nil : .endsAgents))
        }
        // A Chief on this app's acpmux (NIGHTLY, ChiefHome.usesAppAcpmux) has no daemon of its
        // own: the Agents row and its restart cover it.
        if !chief.home.usesAppAcpmux, let environment = ChiefHomeAcpmux.environment(home: chief.home) {
            let builds = await AcpmuxServiceRestart(environment: environment).builds()
            // Only the Chief host starts this daemon (cx-ebm.54): without one it would stay stopped.
            let hostRuns = ChiefHostStop.runningHostPID(home: chief.home) != nil
            let skip: BackgroundService.Skip? = !builds.keepsAgents ? .endsAgents : hostRuns ? nil : .restartsWithChief
            list.append(BackgroundService(role: .chiefAgents, running: builds.running, bundled: builds.bundled, skip: skip))
        }
        return BackgroundServicesReport(services: list)
    }

    /// Restarts each running service that keeps its work. The acpmux homes go first; the session
    /// owner last, since its handoff reconnects this app.
    func restart(_ report: BackgroundServicesReport) async -> BackgroundServicesRestartResult {
        var result = BackgroundServicesRestartResult()
        guard let services else { return result }
        let due = Set(report.services.filter(\.restarts).map(\.role))
        if due.contains(.agents), let host = services.agentTabs.host as? AcpmuxHost {
            let chiefHome = services.home.chief.home
            // A Chief on this daemon (NIGHTLY) never has its turn cut: its host hands off when its
            // turn ends and exits, and the restart runs then; the brain keeper starts the next host.
            if afterTurnRestart != nil {
                // One already waits for the Chief's turn: it restarts this daemon then.
                result.afterTurn.append(.agents)
            } else if chiefHome.usesAppAcpmux, let chiefHost = ChiefHostStop.askToHandOffWhenIdle(home: chiefHome) {
                let logger = logger
                // task-owner: `afterTurnRestart`, one at a time; it ends when the Chief host exited and the daemon restarted
                afterTurnRestart = Task { @MainActor [weak self, weak services] in
                    _ = await AgentPaneProcessExit(pid: chiefHost).event(within: nil)
                    do {
                        try await host.restartDaemon()
                    } catch {
                        logger.error("acpmux restart after the Chief's turn failed: \(String(describing: error), privacy: .public)")
                    }
                    _ = services?.home.brain.ensure(asked: false)
                    self?.afterTurnRestart = nil
                }
                result.afterTurn.append(.agents)
            } else {
                do {
                    try await host.restartDaemon()
                    result.restarted.append(.agents)
                } catch {
                    result.failed.append(.init(role: .agents, reason: .other(String(describing: error))))
                }
                if chiefHome.usesAppAcpmux { _ = services.home.brain.ensure(asked: false) }
            }
        }
        if due.contains(.chiefAgents), !services.home.chief.home.usesAppAcpmux,
           let environment = ChiefHomeAcpmux.environment(home: services.home.chief.home) {
            let heal = ChiefAcpmuxHeal(home: services.home.chief.home, environment: environment) { [weak services] in
                await MainActor.run { _ = services?.home.brain.ensure(asked: false) }
            }
            switch await heal.restart() {
            case .handOff: result.restarted.append(.chiefAgents)
            case .waitForHost: result.afterTurn.append(.chiefAgents)
            case .keep: result.failed.append(.init(role: .chiefAgents, reason: .refused))
            }
        }
        if due.contains(.chiefOwner) {
            if await services.home.chief.restartOnBundledBuild() {
                result.restarted.append(.chiefOwner)
            } else {
                result.failed.append(.init(role: .chiefOwner, reason: .refused))
            }
        }
        if due.contains(.sessionOwner) {
            let before = services.daemon.identity?.pid
            if await services.daemon.restartForUpdate() != nil {
                result.restarted.append(.sessionOwner)
            } else {
                // The same owner still answers: it refused (an external binary, or a handoff
                // already spent on it); else the next one did not connect in time.
                let refused = before != nil && services.daemon.identity?.pid == before
                result.failed.append(.init(role: .sessionOwner, reason: refused ? .refused : .didNotReturn))
            }
        }
        return result
    }
}
