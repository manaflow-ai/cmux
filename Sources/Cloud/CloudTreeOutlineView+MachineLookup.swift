import CmuxCloud
import CmuxSurfaceCatalogModel

extension CloudTreeOutlineView.Coordinator {
    /// Finds a Cloud machine anywhere in the displayed tree, including under its section row.
    func machine(id: SurfaceMachineID) -> MachineSnapshot? {
        for node in CloudTreeNodeBuilder.flattened(nodes) {
            if case .machine(let machine, _) = node.kind, .cloud(machine.id) == id { return machine }
        }
        return nil
    }
}
