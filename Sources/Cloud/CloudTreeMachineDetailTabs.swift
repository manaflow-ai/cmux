import CmuxSurfaceCatalogModel

/// The tab row under a Cloud machine: which detail groups the machine has,
/// their counts, and which one is open. A nil count means the tab shows no
/// number (Resources); a missing tab means the machine has no such group.
struct CloudTreeMachineDetailTabs: Equatable {
    let machine: SurfaceMachineID
    var tabs: [CloudTreeMachineDetailTab]
    var counts: [CloudTreeMachineDetailTab: Int]
    var selected: CloudTreeMachineDetailTab?

    func count(for tab: CloudTreeMachineDetailTab) -> Int? { counts[tab] }
}
