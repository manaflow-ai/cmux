import AppKit
import CmuxSurfaceCatalogModel

/// Separates an explicit disclosure operation from AppKit's descendant callbacks.
@MainActor
final class CloudTreeDisclosureScope {
    private enum Operation {
        case item(CloudTreeNode)
        case roots
        case recursive
    }

    private var operation: Operation?
    private var refreshedMachines: Set<SurfaceMachineID> = []
    var withPersistenceBatch: (() -> Void) -> Void = { $0() }

    func perform(item: Any?, recursive: Bool, _ action: () -> Void) {
        // AppKit can enter the public method again while changing descendants.
        // The outer request remains the authority for what the person chose.
        guard operation == nil else { action(); return }
        if recursive { operation = .recursive }
        else if let node = item as? CloudTreeNode { operation = .item(node) }
        else { operation = .roots }
        defer {
            operation = nil
            refreshedMachines.removeAll(keepingCapacity: true)
        }
        withPersistenceBatch(action)
    }

    func records(_ node: CloudTreeNode, in outline: NSOutlineView) -> Bool {
        switch operation {
        case .item(let requested): return requested === node
        case .roots: return outline.parent(forItem: node) == nil
        case .recursive: return true
        case nil: return false
        }
    }

    func shouldRefresh(_ machine: SurfaceMachineID) -> Bool {
        refreshedMachines.insert(machine).inserted
    }
}
