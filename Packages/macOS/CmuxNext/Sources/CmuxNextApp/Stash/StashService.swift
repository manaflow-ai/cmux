import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHistory
import Foundation

/// Stash (a native OneTab, `stash-v1`) on this Mac's daemon: serves the
/// Stashed page (`StashPageSource`) and closes tabs into stashes for the
/// Stash actions. The page's model is the one list every surface reads.
final class StashService: StashPageSource {
    private unowned let services: AppServices
    let model = StashPageModel()

    init(services: AppServices) {
        self.services = services
        model.source = self
    }

    /// Whether `daemon` keeps stashes; without it no stash UI shows. Only this Mac's daemon.
    func serves(_ daemon: DaemonService) -> Bool { daemon.isLocal && daemon.supports(DaemonCapabilities.shared.stash) }

    /// Closes browser tabs `tabs` (or the unpinned pages of `workspace`) into one stash.
    func stash(tabs: [ResourceID], workspace: ResourceID?) {}

    // MARK: StashPageSource

    func stashes() async throws -> [StashedGroup] { [] }

    func restore(_ group: StashedGroup, tabs: [Int]?, inNewWorkspace: Bool) async throws {}

    func delete(_ group: StashedGroup, tabs: [Int]?) async throws {}

    func importGroups(_ groups: [OneTabExport.Group]) async throws {}
}
