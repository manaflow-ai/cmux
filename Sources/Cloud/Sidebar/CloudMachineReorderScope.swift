/// The rows a machine reorders among. A tree with only the fleet lists
/// machines at the root; the live Cloud tab lists them under the Cloud
/// Machines section, ahead of My Devices.
struct CloudMachineReorderScope {
    /// The section that holds the machines, nil when they are roots.
    let parent: CloudTreeNode?
    let siblings: [CloudTreeNode]

    private init(parent: CloudTreeNode?, siblings: [CloudTreeNode]) {
        self.parent = parent
        self.siblings = siblings
    }

    /// Resolves the single sibling list that owns machine reordering.
    static func resolve(machineNodeID: String? = nil, roots: [CloudTreeNode]) -> CloudMachineReorderScope? {
        let rootMatches = roots.filter { node in
            node.canReorderMachine && (machineNodeID == nil || node.id == machineNodeID)
        }
        if !rootMatches.isEmpty { return .init(parent: nil, siblings: roots) }
        guard let section = roots.first(where: { root in
            root.children.contains { node in
                node.canReorderMachine && (machineNodeID == nil || node.id == machineNodeID)
            }
        }) else { return nil }
        return .init(parent: section, siblings: section.children)
    }

    init?(machineNodeID id: String, roots: [CloudTreeNode]) {
        guard let resolved = Self.resolve(machineNodeID: id, roots: roots) else { return nil }
        self = resolved
    }

    /// Rebuilds the machine rows of `roots` with `reorder`, wherever they sit.
    static func replacingMachines(
        in roots: [CloudTreeNode], with reorder: ([CloudTreeNode]) -> [CloudTreeNode]
    ) -> [CloudTreeNode] {
        guard let resolved = resolve(roots: roots) else { return roots }
        if let parent = resolved.parent {
            parent.children = reorder(parent.children)
            return roots
        }
        return reorder(roots)
    }
}
