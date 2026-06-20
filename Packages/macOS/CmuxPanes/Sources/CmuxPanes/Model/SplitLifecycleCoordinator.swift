public import Foundation
public import Observation
public import Bonsplit

/// The per-workspace split-lifecycle sub-model: owns the post-close
/// bookkeeping the legacy `Workspace` god object kept as loose stored
/// properties (`postCloseSelectTabId`, `postCloseClearSplitZoomTabIds`) and
/// drove from inside its `BonsplitDelegate` conformance.
///
/// When Bonsplit asks the delegate whether a tab may close
/// (`splitTabBar(_:shouldCloseTab:inPane:)`), the workspace records, against
/// the *pre-close* tree, which sibling tab should become selected once the
/// close lands and whether closing this tab also collapses a split zoom.
/// Bonsplit then performs the close and calls
/// `splitTabBar(_:didCloseTab:fromPane:)`, where the workspace consumes those
/// recorded decisions. This model owns that record/consume pair so the
/// `Workspace` delegate methods forward to it.
///
/// The split tree itself lives in `BonsplitController`; this model only owns
/// the workspace-side `TabID`-keyed bookkeeping around it. None of the
/// recorded state was `@Published` on the legacy god object, so this storage
/// move carries no observer-parity hooks (matching ``SplitLayoutModel``).
@MainActor
@Observable
public final class SplitLifecycleCoordinator {
    /// The tab to select after a given tab closes, keyed by the closing tab's
    /// id (legacy `Workspace.postCloseSelectTabId`). Recorded against the
    /// pre-close tab order in ``recordPostCloseState(controller:closing:inPane:)``
    /// and consumed in ``consumePostCloseSelectTabId(forClosed:)``.
    public var postCloseSelectTabId: [TabID: TabID] = [:]

    /// The set of closing tab ids whose close should also clear the split
    /// zoom, because the closing tab is the selected tab of the currently
    /// zoomed pane (legacy `Workspace.postCloseClearSplitZoomTabIds`).
    public var postCloseClearSplitZoomTabIds: Set<TabID> = []

    /// Creates an idle model; the owning workspace drives it from its
    /// `BonsplitDelegate` close flow.
    public init() {}

    /// Records, against the *pre-close* tree, the post-close decisions for a
    /// tab Bonsplit is about to close in `pane`: whether the close also clears
    /// the split zoom, and which sibling tab should become selected afterward
    /// (legacy nested `recordPostCloseState()` in
    /// `Workspace.splitTabBar(_:shouldCloseTab:inPane:)`).
    ///
    /// The zoom-clear flag is set only when `pane` is the zoomed pane and the
    /// closing tab is that pane's selected tab. The post-close selection picks
    /// the next tab in pane order, falling back to the previous one, and clears
    /// the entry when the closing tab is the pane's only tab or is not found.
    public func recordPostCloseState(
        controller: BonsplitController,
        closing tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) {
        if controller.zoomedPaneId == pane,
           controller.selectedTab(inPane: pane)?.id == tab.id {
            postCloseClearSplitZoomTabIds.insert(tab.id)
        } else {
            postCloseClearSplitZoomTabIds.remove(tab.id)
        }

        let tabs = controller.tabs(inPane: pane)
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else {
            postCloseSelectTabId.removeValue(forKey: tab.id)
            return
        }

        let target: TabID? = {
            if idx + 1 < tabs.count { return tabs[idx + 1].id }
            if idx > 0 { return tabs[idx - 1].id }
            return nil
        }()

        if let target {
            postCloseSelectTabId[tab.id] = target
        } else {
            postCloseSelectTabId.removeValue(forKey: tab.id)
        }
    }

    /// Removes and returns the recorded post-close selection target for a
    /// closed tab, if one was recorded (legacy
    /// `postCloseSelectTabId.removeValue(forKey: tabId)` in
    /// `Workspace.splitTabBar(_:didCloseTab:fromPane:)`).
    public func consumePostCloseSelectTabId(forClosed tabId: TabID) -> TabID? {
        postCloseSelectTabId.removeValue(forKey: tabId)
    }

    /// Removes the closed tab from the zoom-clear set, reporting whether it was
    /// present and therefore whether the close should clear the split zoom
    /// (legacy `postCloseClearSplitZoomTabIds.remove(tabId) != nil` in
    /// `Workspace.splitTabBar(_:didCloseTab:fromPane:)`).
    public func consumeShouldClearSplitZoom(forClosed tabId: TabID) -> Bool {
        postCloseClearSplitZoomTabIds.remove(tabId) != nil
    }
}
