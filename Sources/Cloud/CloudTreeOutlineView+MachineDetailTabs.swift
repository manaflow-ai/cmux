import CmuxFoundation
import AppKit
import CmuxSurfaceCatalogModel

extension CloudTreeOutlineView.Coordinator {
    /// Opens `tab` on a machine's tab row, or closes it, then re-presents the
    /// current tree. Opening Ports or Displays refreshes the machine, as
    /// expanding their groups used to, and Ports also asks for port discovery.
    func toggleMachineDetailTab(_ tab: CloudTreeMachineDetailTab, machine: SurfaceMachineID) {
        let opened = machineDetailLayout.toggle(tab, machine: machine)
        applyOrganization(nodes: organizationNodes)
        if opened == .ports || opened == .displays {
            nodeActions.refreshMachine(machine)
        }
        if opened == .ports {
            portsDemand.schedule(coordinator: self)
        }
        if opened == .displays {
            displaysDemand.request(machine, actions: nodeActions)
        }
    }
}

/// Requests guest display discovery once per machine whose Displays tab is
/// open, including a tab restored as selected. Discovery starts the guest
/// helper and its standby display before the first New Display.
@MainActor
final class CloudDisplaysDiscoveryDemand {
    private var requested: Set<SurfaceMachineID> = []

    func update(nodes: [CloudTreeNode], actions: CloudTreeNodeActions) {
        var shown: Set<SurfaceMachineID> = []
        for node in CloudTreeNodeBuilder.flattened(nodes) {
            if case .machineDetailTabs(let tabs) = node.kind, tabs.selected == .displays {
                shown.insert(tabs.machine)
            }
        }
        // A machine that leaves the tree, or whose tab closes, asks again next time.
        requested.formIntersection(shown)
        for machine in shown where !requested.contains(machine) {
            request(machine, actions: actions)
        }
    }

    func request(_ machine: SurfaceMachineID, actions: CloudTreeNodeActions) {
        requested.insert(machine)
        actions.discoverDisplays(machine)
    }
}

extension CloudTreeNSOutlineView {
    /// An open machine tab's rows start under the first tab, not one indent
    /// deeper than the tab row; nil for every other row.
    func panelContentLeading(atRow row: Int) -> CGFloat? {
        guard let level = tabRowLevel(ofChildAt: row) else { return nil }
        let leading = CloudTreeMachineDetailTabsView.panelContentLeading(tabRowLevel: level, style: treeStyle)
        // Resource readings have no icon, so their text starts where the
        // other rows' glyphs do: on the first tab's title.
        if let node = item(atRow: row) as? CloudTreeNode, case .resource = node.kind {
            return leading + GlobalFontMagnification.scaledSize(max(0, treeStyle.iconSlot - treeStyle.iconSize) / 2)
        }
        return leading
    }

    /// The level of the machine tab row that owns the row at `row`, if any.
    func tabRowLevel(ofChildAt row: Int) -> Int? {
        guard let item = item(atRow: row),
              let parent = parent(forItem: item) as? CloudTreeNode,
              case .machineDetailTabs = parent.kind else { return nil }
        return level(forItem: parent)
    }
}
