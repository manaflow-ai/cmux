public import CmuxNextDaemon
import Foundation

extension DaemonService {
    /// Starts the shells of `workspace`'s parked tabs (`park-tabs`,
    /// `relaunch.onShow`): a window calls it when it shows the workspace, so a
    /// terminal the classic migration brought over in the background starts on
    /// its first show. Each tab restarts once (`restart-tab`); a failed one
    /// stays dead with its Restart button. A kept tab in a protected folder waits here too
    /// (``TabRelaunch/startsOnShow(home:)``, LAUNCH-NO-TCC-PROMPTS).
    public func wakeParkedTabs(in workspace: WorkspaceModel) {
        guard supports(DaemonCapability.tabRestartKeptLayout.rawValue), let connection else { return }
        let surfaces = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
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
}
