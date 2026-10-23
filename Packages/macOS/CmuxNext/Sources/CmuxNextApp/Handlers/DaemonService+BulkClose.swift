import CmuxNextDaemon
import CmuxNextDaemonService

extension DaemonService {
    /// Whether this daemon takes a close gesture over several screens or
    /// workspaces as one `layout.bulk` request (`BulkClosePlan`).
    var servesBulkClose: Bool {
        store.servesStateResources && supports(DaemonCapabilities.shared.layoutBulk)
    }
}
