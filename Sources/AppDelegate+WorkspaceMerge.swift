import Bonsplit
import Foundation

/// A sidebar workspace dropped on a pane brings its tabs in (cmux-next #17542).
/// The pane's center adds every tab at the drop index; an edge splits the pane
/// with the first tab and the rest follow into that new pane, in sidebar order.
/// Each tab moves with the existing cross-workspace move, so the emptied
/// workspace closes the way it does after its last tab is dragged out.
extension AppDelegate {
    /// Whether `sourceId`'s tabs may move into `targetId`: two different live
    /// workspaces, neither a remote tmux mirror (its panes belong to the
    /// mirror), and every tab allowed on the target's machine.
    func canMergeWorkspace(_ sourceId: UUID, into targetId: UUID) -> Bool {
        guard sourceId != targetId,
              let source = mergeWorkspace(id: sourceId),
              let target = mergeWorkspace(id: targetId),
              !source.isRetiredFromOwningTabManager, !target.isRetiredFromOwningTabManager,
              !source.isRemoteTmuxMirror, !target.isRemoteTmuxMirror else { return false }
        let panelIds = source.sidebarOrderedPanelIds()
        return !panelIds.isEmpty && panelIds.allSatisfy { target.acceptsSurface(from: source, panelID: $0) }
    }

    /// Moves every tab of `sourceId` to `destination` in `targetId`. False when
    /// the merge is refused or the first tab cannot move; a later tab that
    /// cannot move stays behind in its workspace.
    @discardableResult
    func mergeWorkspace(
        _ sourceId: UUID,
        into targetId: UUID,
        destination: BonsplitController.ExternalTabDropRequest.Destination,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
        guard canMergeWorkspace(sourceId, into: targetId),
              let source = mergeWorkspace(id: sourceId),
              let target = mergeWorkspace(id: targetId),
              let targetManager = tabManagerFor(tabId: targetId) else { return false }
        let panelIds = source.sidebarOrderedPanelIds()
        guard let lead = panelIds.first else { return false }
        let leadMoved: Bool
        switch destination {
        case .insert(let pane, let index):
            leadMoved = moveSurface(panelId: lead, toWorkspace: targetId, targetPane: pane, targetIndex: index,
                                    focus: false, focusWindow: false)
        case .split(let pane, let orientation, let insertFirst):
            leadMoved = moveSurface(panelId: lead, toWorkspace: targetId, targetPane: pane,
                                    splitTarget: (orientation, insertFirst), focus: false, focusWindow: false)
        }
        guard leadMoved, let landedPane = target.paneId(forPanelId: lead) else { return false }
        // The rest follow the lead, in order, into the pane it landed in.
        var nextIndex = target.indexInPane(forPanelId: lead).map { $0 + 1 }
        for panelId in panelIds.dropFirst() {
            guard moveSurface(panelId: panelId, toWorkspace: targetId, targetPane: landedPane, targetIndex: nextIndex,
                              focus: false, focusWindow: false) else { break }
            nextIndex = nextIndex.map { $0 + 1 }
        }
        if focus {
            if focusWindow, let windowId = windowId(for: targetManager) {
                _ = focusMainWindow(windowId: windowId)
            }
            targetManager.focusTab(targetId, surfaceId: lead, suppressFlash: true)
        }
        return true
    }

    private func mergeWorkspace(id: UUID) -> Workspace? {
        tabManagerFor(tabId: id)?.tabs.first { $0.id == id }
    }
}
