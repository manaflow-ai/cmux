import AppKit

extension CloudTreeOutlineView.Coordinator {
    func restoreSelection(in outlineView: NSOutlineView) {
        if let selectedNodeID {
            for row in 0..<outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? CloudTreeNode,
                   node.id == selectedNodeID {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    updateSelection(from: node)
                    return
                }
            }
        }
        // A missing or hidden row has no create destination. Clear the owner
        // as well as AppKit so a later rebuild cannot revive that selection.
        outlineView.deselectAll(nil)
        updateSelection(from: nil)
    }

    /// The coordinator owns selection; consumers receive only its current value snapshot.
    func updateSelection(from node: CloudTreeNode?) {
        selectedNodeID = node?.id
        let selection = node.flatMap(selectionContext)
        pendingSelectionPublication?.cancel()
        pendingSelectionPublication = nil
        if isUpdatingProgrammatically {
            // Representable updates may reconcile the native outline immediately,
            // but must publish back into SwiftUI only after that update returns.
            pendingSelectionPublication = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.pendingSelectionPublication = nil
                self.publishSelection(selection)
            }
        } else {
            publishSelection(selection)
        }
    }

    private func publishSelection(_ selection: CloudTreeCreateSelection?) {
        guard !hasPublishedSelection || lastPublishedSelection != selection else { return }
        hasPublishedSelection = true
        lastPublishedSelection = selection
        onSelectionChange(selection)
    }

    func selectionContext(for node: CloudTreeNode) -> CloudTreeCreateSelection? {
        switch node.kind {
        case .machine(let machine, _):
            return .machine(.cloud(machine.id))
        case .workspacesGroup(let machine), .terminalsPool(let machine, _), .displaysPool(let machine, _), .portsGroup(let machine), .browsersGroup(let machine):
            return machine.isLocal ? nil : .machine(machine)
        case .workspace(let machine, let workspace, _, _, _):
            return .workspace(machine: machine, workspaceID: workspace.id, workspaceName: workspace.name)
        case .createWorkspace(let machine, _):
            return .machine(machine)
        case .createTerminal(let machine, let workspaceID, let workspaceName):
            return .workspace(machine: machine, workspaceID: workspaceID, workspaceName: workspaceName)
        default:
            return nil
        }
    }
}
