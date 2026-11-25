#if os(iOS)
import CmuxMobileModel
import Foundation

/// The tab on screen stays on screen (Leo, 2026-11-21: "i lost connection with cosmic gray or some s***
/// refreshed or the connection f***ing lagged and then it brought me out of the terminal tab and into a
/// browser tab").
///
/// A reconnect, a resync or a partial tree can publish the workspace without the tab the person is on.
/// `activeTabID` then fell back to the opening tab, which prefers the Mac's focused or top-left tab: often
/// a browser. Now the selected tab is held in the list at its old place until it comes back, the person
/// picks another tab, or the Mac, linked, has left it out for `selectionHoldGrace` (gone for good). Only
/// then does the selection move, to its neighbour, as a closed tab's does.
extension WorkspaceTabsSource {
    /// How long a linked Mac may leave the selected tab out before it counts as closed.
    static let selectionHoldGrace: Duration = .seconds(10)

    /// The tab beside a removed one at `index`: the one that took its place, else the one before it.
    static func neighbour(at index: Int, in tabs: [WorkspaceTab]) -> WorkspaceTab? {
        guard !tabs.isEmpty else { return nil }
        return tabs[min(max(index, 0), tabs.count - 1)]
    }

    /// Removes a tab from the store on this screen's own action, so it is not held.
    @discardableResult
    func removeTabHere(_ id: String) -> WorkspaceTab? {
        removedHere.insert(id)
        return store.removeTab(id, from: workspaceID)
    }

    /// `published` with the selected tab put back at its old place while the hold lasts.
    func holdSelectedTab(in published: Workspace?, linked: Bool) -> Workspace? {
        // A workspace briefly missing (a resync replacing the Mac's list) keeps the hold for its return.
        guard var workspace = published else { return nil }
        guard let id = selectedTabID, id != Self.screenSharingTabID else { return releaseHold(workspace) }
        if let index = workspace.tabs.firstIndex(where: { $0.id == id }) {
            removedHere.remove(id)
            stopHoldClock()
            heldTab = (workspace.tabs[index], index)
            return workspace
        }
        // A tab picked since the last publish (`activate` does not refresh) is held from the list on screen.
        if heldTab?.tab.id != id {
            stopHoldClock()
            let shown = workspaceSnapshot?.tabs ?? []
            heldTab = shown.firstIndex { $0.id == id }.map { (shown[$0], $0) }
        }
        guard let held = heldTab, held.tab.id == id, !removedHere.contains(id),
              !store.pendingWorkspaceIDs.contains(workspace.id) else {
            return releaseHold(workspace)
        }
        if linked, heldGraceDone {
            // Gone for good: its neighbour, as a closed tab's.
            selectedTabID = Self.neighbour(at: held.index, in: workspace.tabs)?.id
            return releaseHold(workspace)
        }
        if linked { startHoldClock() } else { stopHoldClock() }
        workspace.tabs.insert(held.tab, at: min(held.index, workspace.tabs.count))
        return workspace
    }

    private func releaseHold(_ workspace: Workspace) -> Workspace {
        if let id = heldTab?.tab.id { removedHere.remove(id) }
        heldTab = nil
        stopHoldClock()
        return workspace
    }

    private func startHoldClock() {
        guard heldGraceTask == nil, !heldGraceDone else { return }
        let clock = clock
        heldGraceTask = Task { @MainActor [weak self] in
            do { try await clock.sleep(for: Self.selectionHoldGrace) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.heldGraceTask = nil
            self.heldGraceDone = true
            self.refreshTabs()
        }
    }

    private func stopHoldClock() {
        heldGraceTask?.cancel()
        heldGraceTask = nil
        heldGraceDone = false
    }
}
#endif
