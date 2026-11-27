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
    }
}

/// Requests guest display discovery once per machine whose Displays tab is
/// open, including a tab restored as selected. Discovery starts the guest
/// helper and its standby display before the first New Display.
@MainActor
final class CloudDisplaysDiscoveryDemand {
    /// The current discovery per machine. A completion from a discovery the
    /// tab has since closed and reopened past no longer matches and is ignored.
    private var requested: [SurfaceMachineID: UUID] = [:]
    /// Failed discoveries per shown machine; retries stop at the limit until
    /// the tab is reopened or the machine leaves and returns to the tree.
    private var failures: [SurfaceMachineID: Int] = [:]
    static let maxAttempts = 3

    func update(nodes: [CloudTreeNode], actions: CloudTreeNodeActions) {
        var shown: Set<SurfaceMachineID> = []
        for node in CloudTreeNodeBuilder.flattened(nodes) {
            if case .machineDetailTabs(let tabs) = node.kind, tabs.selected == .displays {
                shown.insert(tabs.machine)
            }
        }
        // A machine that leaves the tree, or whose tab closes, asks again next time.
        requested = requested.filter { shown.contains($0.key) }
        failures = failures.filter { shown.contains($0.key) }
        for machine in shown where requested[machine] == nil {
            request(machine, actions: actions)
        }
    }

    /// A machine that cannot answer yet (asleep, still connecting) is not
    /// marked, so a later tree update after it wakes asks again. A discovery
    /// that runs but fails is retried right away, a bounded number of times:
    /// starting it is not the same as finishing it.
    private func request(_ machine: SurfaceMachineID, actions: CloudTreeNodeActions) {
        guard failures[machine, default: 0] < Self.maxAttempts else { return }
        // Registered before the call, so a completion that runs synchronously
        // still finds its own token.
        let token = UUID()
        requested[machine] = token
        let started = actions.discoverDisplays(machine) { [weak self] succeeded in
            guard let self, self.requested[machine] == token else { return }
            if succeeded {
                self.failures[machine] = nil
                return
            }
            self.failures[machine, default: 0] += 1
            self.requested[machine] = nil
            self.request(machine, actions: actions)
        }
        if !started, requested[machine] == token { requested[machine] = nil }
    }
}

extension CloudTreeNSOutlineView {
    /// A machine's "Connecting…" row stands where its New Workspace will be,
    /// so its spinner takes the same chevron column as New Workspace's "+"
    /// (`CloudTreeCellView.createRowContentInset`); nil for every other row.
    func connectingLeading(atRow row: Int) -> CGFloat? {
        guard let node = item(atRow: row) as? CloudTreeNode,
              case .placeholder(_, let placeholder) = node.kind, placeholder.style == .connecting,
              let parent = parent(forItem: node) as? CloudTreeNode, parent.isMachineRow else { return nil }
        let slot = max(treeStyle.iconSlot, 12)
        return disclosureLeading(atRow: row)
            + GlobalFontMagnification.scaledSize(treeStyle.rowGrid.disclosureSlot / 2 - slot / 2)
    }

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
