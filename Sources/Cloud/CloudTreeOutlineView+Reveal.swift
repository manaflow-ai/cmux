import AppKit
import Foundation

extension CloudTreeOutlineView.Coordinator {
    enum RevealResult: Equatable {
        case ignored
        case waiting
        case consumed
    }

    /// Selects a requested row once, expanding its ancestors and the row itself.
    @discardableResult
    func reveal(
        _ request: CloudTreeRevealRequest?,
        channel: RevealChannel = .device
    ) -> RevealResult {
        guard let request else {
            if let previous = pendingRevealByChannel[channel] {
                cancelPendingReveal(previous, channel: channel)
            }
            return .ignored
        }
        guard !consumedRevealTokens.contains(request.token) else { return .consumed }
        guard let outlineView else { return .waiting }
        if let previous = pendingRevealByChannel[channel], previous != request.token {
            cancelPendingReveal(previous, channel: channel)
        }
        pendingRevealByChannel[channel] = request.token
        pendingRevealTokens.insert(request.token)
        guard let path = request.path(in: nodes), let node = path.last else { return .waiting }
        expand(path.dropLast(), in: outlineView)
        if node.isExpandable { expand([node], in: outlineView) }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return .waiting }
        withProgrammaticUpdate {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard outlineView.selectedRow == row else { return .waiting }
        selectedNodeID = node.id
        rememberConsumedRevealToken(request.token)
        pendingRevealTokens.remove(request.token)
        pendingRevealByChannel.removeValue(forKey: channel)
        scrollRowFullyIntoView(row, in: outlineView)
        return .consumed
    }

    /// Cancels a reveal whose row never became selectable, and releases the
    /// one-shot request in the model that created it. Without this callback a
    /// late catalog update can replay a request after the user selected another
    /// row.
    func cancelPendingReveal(_ token: UUID, channel: RevealChannel) {
        guard pendingRevealByChannel[channel] == token else { return }
        pendingRevealByChannel.removeValue(forKey: channel)
        pendingRevealTokens.remove(token)
        rememberConsumedRevealToken(token)
        let callback = channel == .device ? onRevealConsumed : onCloudWorkspaceRevealConsumed
        Task { @MainActor in callback?(token) }
    }

    func rememberConsumedRevealToken(_ token: UUID) {
        guard consumedRevealTokens.insert(token).inserted else { return }
        consumedRevealTokenOrder.append(token)
        while consumedRevealTokenOrder.count > maxConsumedRevealTokens {
            let oldest = consumedRevealTokenOrder.removeFirst()
            consumedRevealTokens.remove(oldest)
        }
    }

    /// Follows this window's workspace creation: selects the new row once it
    /// exists, expanding its machine and Workspaces group, and puts the prior
    /// selection back when the create is withdrawn. It never moves keyboard
    /// focus, and a newer selection always wins.
    func reveal(creation request: CloudWorkspaceCreationReveal?) {
        // A drag defers node updates; the next update after it ends catches up.
        guard !isDragging, let outlineView else { return }
        let action = creationRevealPresentation.update(request: request, selectedNodeID: selectedNodeID) { id in
            CloudTreeNode.path(to: id, in: nodes) != nil
        }
        switch action {
        case .select(let id)?:
            guard let path = CloudTreeNode.path(to: id, in: nodes), let node = path.last else { return }
            expand(path.dropLast(), in: outlineView)
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            // A regular selection change records the row, so reloads restore it.
            withProgrammaticUpdate {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if outlineView.selectedRow == row {
                    selectedNodeID = id
                }
            }
            // The outline view refuses rows it cannot select; retry those later.
            guard outlineView.selectedRow == row else { return }
            scrollRowFullyIntoView(row, in: outlineView)
            creationRevealPresentation.didSelect(id)
        case .restore(let baseline)?:
            selectedNodeID = baseline
            withProgrammaticUpdate { restoreSelection(in: outlineView) }
            // The reveal scrolled away from the prior row; bring it back.
            if outlineView.selectedRow >= 0 {
                scrollRowFullyIntoView(outlineView.selectedRow, in: outlineView)
            }
        case nil:
            break
        }
    }

    private func expand(_ nodes: some Sequence<CloudTreeNode>, in outlineView: NSOutlineView) {
        for node in nodes where !outlineView.isItemExpanded(node) {
            expansionStore.setExpanded(true, node: node)
            outlineView.expandItem(node)
        }
    }

    /// `scrollRowToVisible` accepts a partially visible row. Reveals need the
    /// whole row visible so a newly selected workspace is not clipped at the
    /// viewport edge after fractional row-height rounding.
    private func scrollRowFullyIntoView(_ row: Int, in outlineView: NSOutlineView) {
        guard row >= 0 else { return }
        let rowRect = outlineView.rect(ofRow: row)
        if !outlineView.visibleRect.contains(rowRect) {
            outlineView.scrollToVisible(rowRect.insetBy(dx: 0, dy: -1))
        }
    }
}

extension CloudTreeNode {
    /// The node with `id` and its ancestors, root first.
    static func path(to id: String, in nodes: [CloudTreeNode]) -> [CloudTreeNode]? {
        for node in nodes {
            if node.id == id { return [node] }
            if let descendants = path(to: id, in: node.children) { return [node] + descendants }
        }
        return nil
    }
}
