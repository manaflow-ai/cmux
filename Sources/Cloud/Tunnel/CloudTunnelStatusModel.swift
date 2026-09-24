import Foundation
import Observation

/// The explicit VPN setup pane's live view of ``CloudTunnelCoordinator``.
/// The coordinator remains the only owner of the state; ordinary Cloud browsing
/// does not observe or display this optional system-wide connection.
@MainActor
@Observable
final class CloudTunnelStatusModel {
    private(set) var status: CloudTunnelStatus?

    var banner: CloudTunnelBanner? {
        status.flatMap(CloudTunnelBanner.init(status:))
    }

    func refresh(_ coordinator: CloudTunnelCoordinator) async {
        status = await coordinator.status()
    }

    /// Follows the coordinator's state until the calling task is cancelled
    /// (the panel's `.task` ends when it leaves the screen).
    func observe(_ coordinator: CloudTunnelCoordinator?) async {
        guard let coordinator else {
            status = nil
            return
        }
        for await _ in await coordinator.stateUpdates() {
            status = await coordinator.status()
        }
    }
}
