import Foundation
import Observation

/// The Machines panel's live view of ``CloudTunnelCoordinator``: the latest
/// status projected as a ``CloudTunnelBanner``. The panel observes it while it
/// is on screen; the coordinator remains the only owner of the state.
@MainActor
@Observable
final class CloudTunnelStatusModel {
    private(set) var status: CloudTunnelStatus?

    var banner: CloudTunnelBanner? {
        status.flatMap(CloudTunnelBanner.init(status:))
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
