public import Foundation
public import Bonsplit

/// The live-workspace operations ``SurfaceRegistryModel`` reaches back into for
/// the panel title / pinned-state / kind logic it owns.
///
/// ``SurfaceRegistryModel`` owns the per-surface registry state (the former
/// `Workspace.pinnedPanelIds`, `Workspace.panelCustomTitleSources`, and the
/// `panelCustomTitles` / `panelTitles` maps it already held) and the pure
/// title/pin/kind transition logic the legacy `Workspace` god object kept inline
/// (`resolvedPanelTitle`, `panelTitle`, `panelKind`, `isPanelPinned`,
/// `setPanelPinned`, `setPanelCustomTitle`, `syncPinnedStateForTab`,
/// `normalizePinnedTabs`, `insertionIndexToRight`).
///
/// Everything those transitions need that is *not* registry state, the live
/// panel set and per-panel display title / kind, the surface-id ↔ panel-id
/// mapping, the owning pane lookup, the authoritative `BonsplitController` tab
/// reads and writes, and the remote-tmux mirror rename, is owned by the app
/// target (the `panels` dictionary of `any Panel`, `bonsplitController`,
/// `paneTree`, and `AppDelegate.shared?.remoteTmuxController`). The app target's
/// `Workspace` conforms and is injected via ``SurfaceRegistryModel/attach(host:)``.
///
/// The seam speaks Bonsplit value types (`TabID`, `PaneID`, `Tab`) directly
/// because `CmuxWorkspaces` already depends on `Bonsplit` (the sibling
/// ``SurfaceLifecycleHosting`` seam does the same); the app-target `any Panel`
/// types never cross into the package, so the panel-kind read is projected to
/// its frozen ``SurfaceKind`` `rawValue` string. Every method mirrors a call the
/// legacy method bodies made on `self` so the move is byte-faithful.
@MainActor
public protocol SurfaceRegistryHosting: AnyObject {
    /// Whether a panel with `panelId` currently exists in the workspace
    /// (legacy `panels[panelId] != nil`).
    func surfaceRegistryPanelExists(_ panelId: UUID) -> Bool

    /// The panel's intrinsic display title used as the fallback when no
    /// auto/custom title applies (legacy `panel.displayTitle`). `nil` when the
    /// panel is absent.
    func surfaceRegistryPanelDisplayTitle(panelId: UUID) -> String?

    /// The panel's surface-kind wire string (legacy `surfaceKind(for: panel)`,
    /// i.e. `SurfaceKind(...).rawValue` switched on `panel.panelType`). `nil`
    /// when the panel is absent. The app-target `any Panel`/`PanelType` types
    /// never cross into the package, so only the frozen `rawValue` string does.
    func surfaceRegistryPanelKind(panelId: UUID) -> String?

    /// The bonsplit surface id (`TabID`) owning the given panel id, or `nil`
    /// when the panel maps to no surface (legacy `surfaceIdFromPanelId`).
    func surfaceRegistrySurfaceId(forPanelId panelId: UUID) -> TabID?

    /// The panel id owning the given bonsplit surface id, or `nil` when the
    /// surface maps to no panel (legacy `panelIdFromSurfaceId`).
    func surfaceRegistryPanelId(forSurfaceId surfaceId: TabID) -> UUID?

    /// The pane id currently owning the given panel id, or `nil` (legacy
    /// `paneId(forPanelId:)`).
    func surfaceRegistryPaneId(forPanelId panelId: UUID) -> PaneID?

    /// The bonsplit tab with the given id, or `nil` (legacy
    /// `bonsplitController.tab(tabId)`).
    func surfaceRegistryTab(_ tabId: TabID) -> Bonsplit.Tab?

    /// The pane's tabs in tab order (legacy `bonsplitController.tabs(inPane:)`).
    func surfaceRegistryTabs(inPane paneId: PaneID) -> [Bonsplit.Tab]

    /// Reorders a tab to the given index within its pane, returning whether the
    /// move took (legacy `bonsplitController.reorderTab(_:toIndex:)`).
    @discardableResult
    func surfaceRegistryReorderTab(_ tabId: TabID, toIndex index: Int) -> Bool

    /// Updates a tab's title and custom-title flag (legacy
    /// `bonsplitController.updateTab(_:title:hasCustomTitle:)`).
    func surfaceRegistryUpdateTab(_ tabId: TabID, title: String, hasCustomTitle: Bool)

    /// Updates a tab's kind and pinned flag (legacy
    /// `bonsplitController.updateTab(_:kind:isPinned:)` with `kind: .some(kind)`).
    func surfaceRegistryUpdateTab(_ tabId: TabID, kind: String, isPinned: Bool)

    /// Updates a tab's pinned flag only, leaving its kind untouched (legacy
    /// `bonsplitController.updateTab(_:isPinned:)`).
    func surfaceRegistryUpdateTab(_ tabId: TabID, isPinned: Bool)

    /// The number of panels currently in the workspace (legacy `panels.count`);
    /// gates the single-panel workspace-title promotion in
    /// ``SurfaceRegistryModel/updatePanelTitle(panelId:title:)``.
    var surfaceRegistryPanelCount: Int { get }

    /// The workspace's custom-title override (legacy `Workspace.customTitle`),
    /// read by ``SurfaceRegistryModel/updatePanelTitle(panelId:title:)`` to skip
    /// the workspace-title promotion when a custom title masks the process title.
    /// Owned by the workspace's title vocabulary (``WorkspaceTitleModel``).
    var surfaceRegistryWorkspaceCustomTitle: String? { get }

    /// The workspace title (legacy `Workspace.title`); the single-panel
    /// promotion in ``SurfaceRegistryModel/updatePanelTitle(panelId:title:)``
    /// reads and writes it. Owned by the workspace's title vocabulary.
    var surfaceRegistryWorkspaceTitle: String { get set }

    /// The workspace process title (legacy `Workspace.processTitle`); the
    /// single-panel promotion reads and writes it. Owned by the workspace's
    /// title vocabulary.
    var surfaceRegistryWorkspaceProcessTitle: String { get set }

    /// Emits the DEBUG `workspace.title.updatePanel` trace for an applied
    /// ``SurfaceRegistryModel/updatePanelTitle(panelId:title:)`` (legacy
    /// `#if DEBUG cmuxDebugLog("workspace.title.updatePanel …")`). The title
    /// preview escaping/truncation stays app-side so the moved body carries no
    /// formatting; called only when the update mutated state.
    func surfaceRegistryLogUpdatePanelTitle(
        panelId: UUID,
        trimmedTitle: String,
        panelCount: Int,
        hasCustomTitle: Bool,
        didMutatePanelTitle: Bool,
        didMutateWorkspaceTitle: Bool
    )

    /// Whether this workspace is a remote tmux mirror (legacy
    /// `isRemoteTmuxMirror`); gates the `rename-window` propagation in
    /// ``SurfaceRegistryModel/setPanelCustomTitle(panelId:title:source:)``.
    var surfaceRegistryIsRemoteTmuxMirror: Bool { get }

    /// Propagates a mirror tab rename to the remote tmux `rename-window`
    /// (legacy `AppDelegate.shared?.remoteTmuxController.handleMirrorWindowRenamed(workspaceId:panelId:title:)`).
    /// Called only when ``surfaceRegistryIsRemoteTmuxMirror`` is `true`.
    func surfaceRegistryHandleMirrorWindowRenamed(panelId: UUID, title: String)
}
