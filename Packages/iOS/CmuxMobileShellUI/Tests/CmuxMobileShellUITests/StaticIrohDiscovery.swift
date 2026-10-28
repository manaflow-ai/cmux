import CMUXMobileCore
import CmuxMobileShell

@MainActor
private final class StaticIrohDiscovery: MobileIrohMacDiscovering {
    let candidates: [MobileDiscoveredIrohMac]

    init(candidates: [MobileDiscoveredIrohMac]) {
        self.candidates = candidates
    }

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        candidates
    }

    func invalidateDiscovery(forMacDeviceID _: String) async {}
}
