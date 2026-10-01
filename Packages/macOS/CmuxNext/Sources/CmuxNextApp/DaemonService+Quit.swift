import CmuxNextDaemon
import Foundation

extension DaemonService {
    /// Quit's end choices on the local daemon: stops this service's
    /// connection and reconnects first (the daemon's exit must not start a
    /// new one), then ends every terminal and stops the daemon
    /// (`shutdown-daemon end_terminals`, which waits for every terminal
    /// host). A failure is logged and the quit goes on: the terminals that
    /// did not end stay for the next launch.
    /// - End Everything closes every local workspace first, so the next
    ///   launch opens one new workspace.
    /// - End Sessions, Keep Layout on a daemon with
    ///   `end-terminals-keep-layout-v1` keeps the tabs, dead, and records each
    ///   tab's directory (`KeptLayoutPlanFile`), so the next launch restarts
    ///   a shell in each with the same splits and ratios
    ///   (`relaunchKeptLayoutIfNeeded`). Older daemons remove the tabs.
    func endSessionsAndStop(_ choice: QuitSessionsChoice) async {
        guard isLocal, choice.ends, let connection else { return }
        guard supports(DaemonCapabilities.shared.terminalReap) else {
            logger.error("end sessions: the daemon lacks \(DaemonCapabilities.shared.terminalReap, privacy: .public)")
            return
        }
        let keepLayout = choice == .endKeepLayout && supports(DaemonCapabilities.shared.endTerminalsKeepLayout)
        if keepLayout, let tree = try? await connection.listWorkspaces() {
            await KeptLayoutPlanFile.forApplication().write(KeptLayoutPlan(tree: tree))
        }
        shutdownConnection()
        do {
            let ended = try await connection.endSessionsAndStop(deletingWorkspaces: choice == .endEverything,
                                                                keepingLayout: keepLayout)
            logger.info("end sessions: ended \(ended.endedTerminals) terminals, kept layout \(ended.keptLayout), daemon stopped")
            if !ended.keptLayout { await KeptLayoutPlanFile.forApplication().remove() }
        } catch {
            logger.error("end sessions failed: \(String(describing: error), privacy: .public)")
            await KeptLayoutPlanFile.forApplication().remove()
        }
    }

    /// After End Sessions, Keep Layout: restarts a shell in every kept tab
    /// the plan lists, in its recorded directory, then forgets the plan.
    func relaunchKeptLayoutIfNeeded(_ connection: DaemonConnection) {
        guard isLocal else { return }
        let file = KeptLayoutPlanFile.forApplication()
        let logger = logger
        // task-owner: one-shot relaunch after connect; the file is removed first so a crash never repeats it
        Task {
            guard let plan = await file.read() else { return }
            await file.remove()
            do {
                let relaunched = try await connection.relaunchKeptTabs(plan)
                logger.info("kept layout: restarted \(relaunched) of \(plan.tabs.count) terminals")
            } catch {
                logger.error("kept layout relaunch failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
