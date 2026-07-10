import AppKit
import Foundation

// User-driven outline -> store write-back (selection, expansion). Split from
// FileExplorerView.swift for the Swift file length budget.
extension FileExplorerPanelView.Coordinator {
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingOutlineProgrammatically,
              let outlineView = notification.object as? NSOutlineView else {
            return
        }
        let nodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
        guard !nodes.isEmpty else { store.select(node: nil); return }
        let anchor = outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode : nil
        store.select(nodes: nodes, anchor: anchor ?? nodes.first)
    }

    // Both handlers ignore programmatic outline mutations (mirroring
    // outlineViewSelectionDidChange): reloadItem(_:reloadChildren:) inside
    // refreshLoadedNodes re-fires expand/collapse notifications, and writing
    // those back into the store bumps its change-generation, which schedules
    // another refresh — a self-sustaining reload loop whenever any folder is
    // expanded. Only user-driven expansion (disclosure click, keyboard) may
    // mutate the store here.
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isUpdatingOutlineProgrammatically,
              let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
        if !store.isExpanded(node) {
            store.expand(node: node)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isUpdatingOutlineProgrammatically,
              let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
        if store.isExpanded(node) {
            store.collapse(node: node)
        }
    }
}
