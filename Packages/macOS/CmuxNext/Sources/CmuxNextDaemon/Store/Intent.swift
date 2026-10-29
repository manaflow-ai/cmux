import Foundation

/// A typed local op the user made that its owner (the daemon) has not
/// settled yet. The store shows it on top of the confirmed mirror
/// (plans/cmux-next/OWNERSHIP-PRINCIPLES.md, "Clients are projections").
/// Applying an intent must be idempotent and conservation-safe: it never
/// adds or removes a tab or a workspace, and it is a no-op when its tab,
/// workspace or group is not in the mirror.
public enum Intent: Sendable, Hashable {
    /// `move-tab`: `surface` into `pane` at final display `index`
    /// (`TabDragOutcome.strip`, a palette or keyboard move).
    case moveTab(surface: SurfaceID, toPane: PaneID, index: Int)
    /// `rename-tab`; nil or empty clears the custom name (shown as nil).
    case renameTab(surface: SurfaceID, name: String?)
    /// `set-tab-pinned`.
    case setTabPinned(surface: SurfaceID, pinned: Bool)
    /// `rename-pane`; nil or empty clears the name (shown as nil).
    case renamePane(pane: PaneID, name: String?)
    /// `rename-screen`; nil or empty clears the name (shown as nil).
    case renameScreen(screen: ScreenID, name: String?)
    /// `set-screen-metadata` with `color` (a palette token); nil clears it.
    case setScreenColor(screen: ScreenID, color: String?)
    /// `set-screen-metadata` with `icon` (an SF Symbol name or one emoji); nil clears it.
    case setScreenIcon(screen: ScreenID, icon: String?)
    /// `set-screen-pinned`.
    case setScreenPinned(screen: ScreenID, pinned: Bool)
    /// `rename-workspace`.
    case renameWorkspace(key: WorkspaceKey, name: String)
    /// `workspace.update` / `set-workspace-metadata` with `color` (a palette name); nil clears it.
    case setWorkspaceColor(key: WorkspaceKey, color: String?)
    /// `move-workspace`: to final daemon-order `index` (clamped).
    case moveWorkspace(key: WorkspaceKey, index: Int)
    /// `move-workspace-to-group` without an index: into `group` (nil
    /// ungroups), keeping its place in the daemon order.
    case setWorkspaceGroup(key: WorkspaceKey, group: WorkspaceGroupID?)
    /// `move-workspace-to-group` with an index: into `group` (nil
    /// ungroups) at final `index` among that section's other members.
    case placeWorkspace(key: WorkspaceKey, group: WorkspaceGroupID?, index: Int)
    /// `update-workspace-group` with `collapsed`.
    case setWorkspaceGroupCollapsed(WorkspaceGroupID, collapsed: Bool)
    /// `update-tab-group` with `collapsed`.
    case setTabGroupCollapsed(TabGroupID, collapsed: Bool)
    /// `set-row-heights` (`rows-v1`): every row of `column`, in permille.
    /// A row divider release (plans/cmux-next/rows.md Z1).
    case setRowHeights(column: ColumnID, heights: [RowHeightValue])
    /// A tab the client is creating (an agent chat tab, `new-conversation-tab`): `provisional`
    /// shows at the end of `pane` until the daemon's tab replaces it (the intent settles) or the
    /// creation fails. Its id and surface come from a ``ProvisionalTab``,
    /// so neither can name a daemon tab.
    case createTab(pane: PaneID, provisional: TabSnapshot)
    /// `bind-conversation-tab-session`: agent chat tab `surface` shows acpmux `session` (the
    /// compare-and-swap's new value) and `harness` (when given) until the daemon's record has
    /// them or refuses them.
    case bindAgentSession(surface: SurfaceID, session: String, harness: String? = nil)
    /// `split` / `new-pane` with client-minted ids (`split-client-keys-v1`): the new pane shows
    /// beside `pane` in the input's frame, under the ids the daemon will use, until the daemon's
    /// pane with the same public id replaces it or the split is refused
    /// (plans/cmux-next/remote-state-ownership.md S3).
    case splitPane(pane: PaneID, direction: SplitDirection, ratio: Double, provisional: ProvisionalPane)
    /// `create-workspace` + its first tab (`new-conversation-tab {workspace, transaction}`): the
    /// workspace shows in the input's frame, at daemon-order `index` (nil: the end), with its one
    /// tab, until the daemon's workspace under the same key holds its first tab or the create
    /// fails (Cmd-N, instant-new-surfaces). Its first tab is a provisional tab, so the
    /// conservation check does not count it.
    case createWorkspace(provisional: ProvisionalWorkspace, index: Int?)
    /// `close-surface` / `close-tabs` of daemon tabs the person closed (Cmd-W, a close button,
    /// close others): they leave the visible records in the input's turn and stay out until the
    /// daemon's records drop them (the reply's sequence is applied and the records no longer hold
    /// them, or a snapshot), or come back when the close fails. One mechanism with the creates,
    /// so a reply that beats its `tab-closed` event never shows the tab again (tab-spam-race).
    case closeTabs(surfaces: [SurfaceID])
}

/// One row's height in permille (`set-row-heights` `heights[]`).
public struct RowHeightValue: Sendable, Hashable, Codable {
    public var row: RowID
    public var height: Int

    public init(row: RowID, height: Int) {
        self.row = row
        self.height = height
    }
}

/// How an intent left the log. Each intent leaves exactly once.
public enum IntentSettlement: Sendable, Hashable {
    /// The daemon's echo of its transaction was applied.
    case echoed
    /// The store applied every event up to the intent's settle sequence
    /// (today the event sequence read after the command's reply; later the
    /// `request-settled` sequence of `mutation-echo-v1`).
    case applied
    /// The command failed.
    case rejected
}
