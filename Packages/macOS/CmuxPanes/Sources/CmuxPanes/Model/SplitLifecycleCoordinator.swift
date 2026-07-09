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

    /// Tab ids allowed to close even when they would normally require
    /// confirmation (legacy `Workspace.forceCloseTabIds`). App-level
    /// confirmation prompts (for example, Close Tab) insert into this set so the
    /// `Workspace` `BonsplitDelegate` close gate doesn't re-block the close after
    /// the user already confirmed. Mutated through ``insertForceCloseTabId(_:)``,
    /// ``removeForceCloseTabId(_:)``, and read through
    /// ``containsForceCloseTabId(_:)``.
    public var forceCloseTabIds: Set<TabID> = []

    /// Tab ids currently showing (or about to show) a close-confirmation prompt
    /// (legacy `Workspace.pendingCloseConfirmTabIds`). Prevents repeated close
    /// gestures (e.g. middle-click spam) from stacking dialogs. Mutated through
    /// ``insertPendingCloseConfirmTabId(_:)``,
    /// ``removePendingCloseConfirmTabId(_:)``, and read through
    /// ``containsPendingCloseConfirmTabId(_:)``.
    public var pendingCloseConfirmTabIds: Set<TabID> = []

    /// The panel ids that were in a pane when a pane-close was approved, keyed
    /// by the closing pane's id (legacy `Workspace.pendingPaneClosePanelIds`).
    /// Bonsplit's pane-close does not emit a per-tab `didCloseTab` callback, so
    /// the delegate records the doomed pane's panel ids against the *pre-close*
    /// tree in `splitTabBar(_:shouldClosePane:)` and consumes them in
    /// `splitTabBar(_:didClosePane:)` to drive per-panel teardown.
    ///
    /// The sibling `Workspace.pendingPaneCloseHistoryEntries` map stays
    /// app-side: it holds the app-target `ClosedPanelHistoryEntry` value, which
    /// this package cannot import, so only the pure `UUID`-keyed panel-id
    /// bookkeeping moves here.
    public var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]

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

    /// Marks a tab id as force-closable so the `BonsplitDelegate` close gate
    /// lets it through (legacy `Workspace.forceCloseTabIds.insert(_:)`).
    public func insertForceCloseTabId(_ tabId: TabID) {
        forceCloseTabIds.insert(tabId)
    }

    /// Clears a tab id's force-closable mark (legacy
    /// `Workspace.forceCloseTabIds.remove(_:)`).
    public func removeForceCloseTabId(_ tabId: TabID) {
        forceCloseTabIds.remove(tabId)
    }

    /// Reports whether a tab id is marked force-closable (legacy
    /// `Workspace.forceCloseTabIds.contains(_:)`).
    public func containsForceCloseTabId(_ tabId: TabID) -> Bool {
        forceCloseTabIds.contains(tabId)
    }

    /// Marks a tab id as having a close-confirmation prompt in flight (legacy
    /// `Workspace.pendingCloseConfirmTabIds.insert(_:)`).
    public func insertPendingCloseConfirmTabId(_ tabId: TabID) {
        pendingCloseConfirmTabIds.insert(tabId)
    }

    /// Clears a tab id's in-flight close-confirmation mark (legacy
    /// `Workspace.pendingCloseConfirmTabIds.remove(_:)`).
    public func removePendingCloseConfirmTabId(_ tabId: TabID) {
        pendingCloseConfirmTabIds.remove(tabId)
    }

    /// Reports whether a tab id already has a close-confirmation prompt in
    /// flight (legacy `Workspace.pendingCloseConfirmTabIds.contains(_:)`).
    public func containsPendingCloseConfirmTabId(_ tabId: TabID) -> Bool {
        pendingCloseConfirmTabIds.contains(tabId)
    }

    /// Records the panel ids present in a pane that Bonsplit is about to close,
    /// keyed by the pane id (legacy `pendingPaneClosePanelIds[pane.id] = panelIds`
    /// in `Workspace.splitTabBar(_:shouldClosePane:)`).
    public func recordPaneClosePanelIds(_ panelIds: [UUID], forPane paneId: UUID) {
        pendingPaneClosePanelIds[paneId] = panelIds
    }

    /// Discards any recorded panel ids for a pane whose close was vetoed before
    /// it ran (legacy `pendingPaneClosePanelIds.removeValue(forKey: pane.id)` on
    /// the confirmation-required veto in `Workspace.splitTabBar(_:shouldClosePane:)`).
    public func clearPaneClosePanelIds(forPane paneId: UUID) {
        pendingPaneClosePanelIds.removeValue(forKey: paneId)
    }

    /// Removes and returns the recorded panel ids for a closed pane, defaulting
    /// to an empty array when none were recorded (legacy
    /// `pendingPaneClosePanelIds.removeValue(forKey: paneId.id) ?? []` in
    /// `Workspace.splitTabBar(_:didClosePane:)`).
    public func consumePaneClosePanelIds(forClosed paneId: UUID) -> [UUID] {
        pendingPaneClosePanelIds.removeValue(forKey: paneId) ?? []
    }

    /// Resolves the name a close-confirmation dialog should use for a panel,
    /// from the panel's cached title metadata (legacy `panelName` resolution in
    /// `Workspace.confirmClosePanel(for:nameOverride:)`).
    ///
    /// The precedence is: a non-blank `nameOverride` (the live foreground
    /// command the mirror-window close path passes so the dialog names the
    /// process the instant the close fires, before the tab's tmux window-name
    /// rename catches up), then the panel's custom title, then its cached
    /// title, then the last path component of its tracked directory; `nil` when
    /// none is set. Each candidate is treated as absent when it trims to empty,
    /// matching the legacy whitespace-and-newlines blank check.
    ///
    /// This is a pure title/metadata transform: the caller resolves the panel
    /// id from the closing surface and reads its own title dictionaries, then
    /// passes the looked-up values in. The dialog string localization and the
    /// NSAlert presentation stay app-side because they bind to the app bundle's
    /// `String(localized:)` catalog and AppKit.
    public func closeConfirmationPanelName(
        nameOverride: String?,
        customTitle: String?,
        title: String?,
        directory: String?
    ) -> String? {
        func nonBlank(_ value: String?) -> String? {
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }

        if let nameOverride = nonBlank(nameOverride) {
            return nameOverride
        }
        if let custom = nonBlank(customTitle) {
            return custom
        }
        if let title = nonBlank(title) {
            return title
        }
        if let dir = nonBlank(directory) {
            return (dir as NSString).lastPathComponent
        }
        return nil
    }
}
