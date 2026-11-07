import CmuxSurfaceCatalogModel

/// The tab row under a Cloud machine: which detail groups the machine has,
/// their counts or discovery markers, and which one is open. A nil count means the tab shows no
/// number (Resources); a missing tab means the machine has no such group.
struct CloudTreeMachineDetailTabs: Equatable {
    let machine: SurfaceMachineID
    var tabs: [CloudTreeMachineDetailTab]
    var counts: [CloudTreeMachineDetailTab: Int]
    var selected: CloudTreeMachineDetailTab?
    /// The latest authoritative port scan state. A closed Ports tab shows an
    /// explicit marker while the eager scan has not completed, rather than
    /// presenting the placeholder's zero children as a settled count.
    var portDiscoveryState: CloudPortDiscoveryState? = nil

    func count(for tab: CloudTreeMachineDetailTab) -> Int? { counts[tab] }

    /// The compact count shown beside a tab, including the in-flight Ports state.
    func countLabel(for tab: CloudTreeMachineDetailTab) -> String? {
        guard tab == .ports, let portDiscoveryState else {
            return counts[tab].map(String.init)
        }
        switch portDiscoveryState {
        case .notRequested: return "?"
        case .loading: return "…"
        default: return counts[tab].map(String.init)
        }
    }
}
