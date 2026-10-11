import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemote
import Foundation

/// The local Chief owner daemon as a machine row ("app adopts", 2026-10-09): the Chief's
/// subagent workspaces live in its owner daemon when `cmux chief` started it without the app,
/// and the app shows that daemon on the paired-server path (ServerReachService.localChief).
extension HomeService {
    /// Shows the row once the Chief owner is connected (its socket is then known), and keeps it
    /// for this run; the row's own session reconnects on its own.
    func showLocalChiefRow() {
        let chief = chief
        // task-owner: one wait for the owner's first connection, then one row add
        Task { [weak self] in
            for await connected in ObservationStream({ chief.connection != nil }) where connected {
                guard let path = await chief.socketPath(), let self else { return }
                let homeID = String(ChiefHomeAcpmux.host(muxHome: chief.home.muxHome).dropFirst("chief:".count))
                guard let reach = try? ServerReach.localChief(homeID: homeID, socket: path, name: HomeStrings.chiefName) else {
                    return
                }
                services.serverReach.localChief = { reach }
                services.serverReach.showLocalChief()
                return
            }
        }
    }
}
