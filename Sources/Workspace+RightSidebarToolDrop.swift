import Bonsplit
import Foundation

extension Workspace {
    /// Opens or repositions one tool at the actual drop location. No Cloud
    /// resource is projected, moved, or created when the tool itself is opened.
    func handleRightSidebarToolDrop(
        mode: RightSidebarMode,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        guard !isRetiredFromOwningTabManager, mode.canOpenAsPane, mode.isAvailable() else { return false }
        let target: PaneID
        switch destination {
        case .insert(let pane, _), .split(let pane, _, _): target = pane
        }
        guard bonsplitController.allPaneIds.contains(target) else { return false }
        let existing = panels.values.compactMap { $0 as? RightSidebarToolPanel }.first { $0.mode == mode }
        guard let panel = existing ?? newRightSidebarToolSurface(inPane: target, mode: mode, focus: false),
              let tab = surfaceIdFromPanelId(panel.id) else { return false }
        let placed: Bool
        switch destination {
        case .insert(let pane, let index):
            placed = bonsplitController.moveTab(tab, toPane: pane, atIndex: index)
        case .split(let pane, let orientation, let insertFirst):
            placed = bonsplitController.splitPane(
                pane, orientation: orientation, movingTab: tab, insertFirst: insertFirst
            ) != nil
        }
        guard placed else {
            if existing == nil { _ = bonsplitController.closeTab(tab) }
            return false
        }
        clearSplitZoom()
        focusPanel(panel.id)
        return true
    }
}
