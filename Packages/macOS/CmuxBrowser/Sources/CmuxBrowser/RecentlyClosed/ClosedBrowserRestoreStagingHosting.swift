public import Foundation
public import Bonsplit

/// The workspace-side reads ``ClosedBrowserRestoreStaging`` performs while
/// deciding whether a closing tab should leave a recently-closed browser
/// restore snapshot staged for `Cmd+Shift+T`.
///
/// The concrete workspace lives in the app target: it owns the Bonsplit split
/// tree, the WebKit `BrowserPanel` instances, the surface-id-to-panel mapping,
/// and the close-history suppression flag, none of which can move down into a
/// package. The app-target workspace conforms to this protocol and the staging
/// coordinator reads each primitive through it, so the package never holds the
/// `Workspace` or any WebKit/AppKit type.
///
/// Each member is the seam for one read the legacy
/// `Workspace.stageClosedBrowserRestoreSnapshotIfNeeded(for:inPane:)` body
/// performed inline: the `suppressClosedPanelHistory` gate, the
/// `panelIdFromSurfaceId`/`browserPanel(for:)` resolution, the
/// `bonsplitController.tabs(inPane:).firstIndex(...)` index lookup, the resolved
/// page url (`currentURL ?? preferredURLStringForOmnibar()`), the
/// `browserIsTemporaryHistoryURL` rejection gate, the workspace identity, the
/// browser profile id, and the `browserCloseFallbackPlan` fields computed off
/// the Bonsplit tree snapshot.
///
/// `@MainActor` because every read touches WebKit/AppKit/Bonsplit state on the
/// main thread, matching the caller (the Bonsplit close delegate runs on the
/// main actor) — the seam lives where its callers live.
@MainActor
public protocol ClosedBrowserRestoreStagingHosting: AnyObject {
    /// The owning workspace's id, stored on every staged snapshot
    /// (legacy `Workspace.id`).
    var stagingWorkspaceId: UUID { get }

    /// Whether close-history capture is currently suppressed; when `true` no
    /// snapshot is staged and any pending entry for the tab is dropped
    /// (legacy `Workspace.suppressClosedPanelHistory`).
    var stagingSuppressClosedPanelHistory: Bool { get }

    /// Resolves the closing surface's panel id, or `nil` when the surface maps to
    /// no panel (legacy `Workspace.panelIdFromSurfaceId(_:)`).
    func stagingPanelId(forSurfaceId surfaceId: TabID) -> UUID?

    /// Whether `panelId` names a live browser panel; only browser panels stage a
    /// restore snapshot (legacy `Workspace.browserPanel(for:) != nil`).
    func stagingIsBrowserPanel(panelId: UUID) -> Bool

    /// The tab index of the closing surface within `pane`, or `nil` when it is
    /// not present (legacy
    /// `bonsplitController.tabs(inPane:).firstIndex(where:)`).
    func stagingTabIndex(forSurfaceId surfaceId: TabID, inPane pane: PaneID) -> Int?

    /// The page url to restore for `panelId`: its current url, else the omnibar's
    /// preferred url string parsed to a `URL` (legacy
    /// `browserPanel.currentURL ?? browserPanel.preferredURLStringForOmnibar().flatMap(URL.init(string:))`).
    func stagingResolvedURL(panelId: UUID) -> URL?

    /// The browser profile id of `panelId`, stored on the snapshot
    /// (legacy `browserPanel.profileID`).
    func stagingProfileID(panelId: UUID) -> UUID?

    /// Whether `url` is a transient history/diff-viewer url that must never be
    /// staged for restore (legacy `browserIsTemporaryHistoryURL(_:)`).
    func stagingIsTemporaryHistoryURL(_ url: URL?) -> Bool

    /// The browser-close fallback placement for `pane`, computed off the Bonsplit
    /// tree snapshot (legacy
    /// `bonsplitController.treeSnapshot().browserCloseFallbackPlan(forPaneId:)`).
    /// Returned as primitive fields so the package never imports the
    /// `CmuxPanes` `BrowserCloseFallbackPlan` type; `nil` when the close needs no
    /// fallback split.
    func stagingFallbackPlan(forPane pane: PaneID) -> ClosedBrowserRestoreFallbackPlan?
}
