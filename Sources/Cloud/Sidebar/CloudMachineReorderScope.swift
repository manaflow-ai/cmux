/// The rows a machine reorders among. A tree with only the fleet lists
/// machines at the root; the live Cloud tab lists them under the Cloud
/// Machines section, ahead of My Devices.
struct CloudMachineReorderScope {
    /// The section that holds the machines, nil when they are roots.
    let parent: CloudTreeNode?
    let siblings: [CloudTreeNode]

    init?(machineNodeID id: String, roots: [CloudTreeNode]) {
        if roots.contains(where: { $0.id == id && $0.canReorderMachine }) {
            parent = nil
            siblings = roots
            return
        }
        guard let section = roots.first(where: { root in
            root.children.contains { $0.id == id && $0.canReorderMachine }
        }) else { return nil }
        parent = section
        siblings = section.children
    }

    /// Rebuilds the machine rows of `roots` with `reorder`, wherever they sit.
    static func replacingMachines(
        in roots: [CloudTreeNode], with reorder: ([CloudTreeNode]) -> [CloudTreeNode]
    ) -> [CloudTreeNode] {
        if roots.contains(where: \.canReorderMachine) { return reorder(roots) }
        for root in roots where root.children.contains(where: \.canReorderMachine) {
            root.children = reorder(root.children)
        }
        return roots
    }
}
