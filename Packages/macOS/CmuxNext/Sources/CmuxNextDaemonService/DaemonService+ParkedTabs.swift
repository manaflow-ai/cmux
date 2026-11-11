public import CmuxNextDaemon
import Foundation

extension DaemonService {
    /// Starts the shells of `workspace`'s parked tabs (`park-tabs`,
    /// `relaunch.onShow`): a window calls it when it shows the workspace, so a
    /// terminal the classic migration brought over in the background starts on
    /// its first show. Each tab restarts once (`restart-tab`); a failed one
    /// stays dead with its Restart button. A kept tab in a protected folder waits here too
    /// (``TabRelaunch/startsOnShow(home:)``, LAUNCH-NO-TCC-PROMPTS).
    ///
    /// A kept tab that the connect already asked for (an agent's) and whose restart still waits
    /// for its turn in the daemon (the restore's line, which stops under memory pressure) is asked
    /// for again, one time: the daemon then starts it at once, in front of the line. The person
    /// went to this workspace, so its terminal does not wait for the agents of the others.
    public func wakeParkedTabs(in workspace: WorkspaceModel) {
        guard supports(DaemonCapability.tabRestartKeptLayout.rawValue), let connection else { return }
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        startWaitingRestartsFirst(tabs, on: connection)
        let surfaces = tabs
            .filter { $0.kind == .pty && $0.dead && $0.relaunch?.startsOnShow() == true && !wakingParkedTabs.contains($0.surface) }
            .map(\.surface)
        guard !surfaces.isEmpty else { return }
        wakingParkedTabs.formUnion(surfaces)
        let logger = logger
        Task { [weak self] in
            for surface in surfaces {
                do {
                    _ = try await connection.request(RestartTabRequest(surface: surface))
                } catch {
                    logger.error("parked tab did not start: \(String(describing: error), privacy: .public)")
                }
                self?.wakingParkedTabs.remove(surface)
            }
        }
    }

    /// The kept tabs of `tabs` whose restart the daemon accepted and has not started yet (the tab
    /// reads `adopting` and still has its `relaunch` record): one more `restart-tab` each. The
    /// daemon starts a restart that waits at once; for one that has its turn it answers
    /// `tab-not-dead`, which is not a failure here.
    private func startWaitingRestartsFirst(_ tabs: [TabModel], on connection: DaemonConnection) {
        let surfaces = tabs
            .filter { $0.kind == .pty && !$0.dead && $0.terminalState == .adopting && $0.relaunch != nil
                && !startedFirstTabs.contains($0.surface) }
            .map(\.surface)
        guard !surfaces.isEmpty else { return }
        startedFirstTabs.formUnion(surfaces)
        let logger = logger
        Task {
            for surface in surfaces {
                do {
                    _ = try await connection.request(RestartTabRequest(surface: surface))
                } catch DaemonError.command(_, _, "tab-not-dead"?, _, _) {
                    // Its restart has its turn already.
                } catch {
                    logger.error("a shown kept tab was not started first: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
