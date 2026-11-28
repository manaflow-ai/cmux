import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

@MainActor
final class FirstReadSuspendedIrohDiscovery: MobileIrohMacDiscovering {
    let pending: SuspendedIrohDiscovery
    private var didRead = false

    init(pending: SuspendedIrohDiscovery) { self.pending = pending }

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        guard !didRead else { return [] }
        didRead = true
        return await pending.discoverLiveMacs()
    }

    func invalidateDiscovery(forMacDeviceID _: String) async {}
}
