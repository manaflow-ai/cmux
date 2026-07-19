import Bonsplit
import Foundation

/// Serializes one workspace's visible pane layout into the share protocol's
/// `LayoutNode` tree. The bonsplit `treeSnapshot()` is the source of truth:
/// split ratios come from each split's `dividerPosition` and each pane node
/// collapses to its selected tab's panel.
@MainActor
enum ShareLayoutSerializer {
    static func sharedWorkspace(for workspace: Workspace) -> ShareSharedWorkspace {
        ShareSharedWorkspace(id: workspace.id.uuidString, title: workspace.title)
    }

    static func layout(for workspace: Workspace) -> ShareWorkspaceLayout {
        ShareWorkspaceLayout(
            ws: workspace.id.uuidString,
            tree: node(from: workspace.bonsplitController.treeSnapshot(), in: workspace)
        )
    }

    private static func node(from treeNode: ExternalTreeNode, in workspace: Workspace) -> ShareLayoutNode? {
        switch treeNode {
        case .pane(let pane):
            return paneNode(from: pane, in: workspace)
        case .split(let split):
            let a = node(from: split.first, in: workspace)
            let b = node(from: split.second, in: workspace)
            switch (a, b) {
            case (.some(let first), .some(let second)):
                // Bonsplit "horizontal" = side by side = share axis "h";
                // "vertical" = stacked = "v". `dividerPosition` is already the
                // first child's fraction of the axis.
                let axis = split.orientation.lowercased() == "vertical" ? "v" : "h"
                let ratio = min(max(split.dividerPosition, 0.01), 0.99)
                return .split(axis: axis, ratio: ratio, a: first, b: second)
            case (.some(let only), .none), (.none, .some(let only)):
                return only
            case (.none, .none):
                return nil
            }
        }
    }

    private static func paneNode(from pane: ExternalPaneNode, in workspace: Workspace) -> ShareLayoutNode? {
        // The visible content of a bonsplit pane is its selected tab's panel.
        let tabIDString = pane.selectedTabId ?? pane.tabs.first?.id
        guard let tabIDString,
              let tabUUID = UUID(uuidString: tabIDString),
              let panel = workspace.panel(for: TabID(uuid: tabUUID)) else {
            return nil
        }
        if let terminal = panel as? TerminalPanel {
            // Pane id must match the surfaceID carried in render-grid frames
            // (`TerminalSurface.id.uuidString`; `TerminalPanel.id` is the same
            // UUID, but read it off the surface to keep the contract explicit).
            let cells = terminal.surface.renderedGridCells()
            return .pane(
                pane: terminal.surface.id.uuidString,
                content: "terminal",
                cols: cells?.columns,
                rows: cells?.rows,
                title: workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle
            )
        }
        let content: String
        if panel is BrowserPanel {
            content = "browser"
        } else if panel is AgentSessionPanel {
            content = "agent"
        } else {
            content = "other"
        }
        return .pane(
            pane: panel.id.uuidString,
            content: content,
            cols: nil,
            rows: nil,
            title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle
        )
    }
}
