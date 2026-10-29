public import CmuxNextLayout
public import CoreGraphics

/// The scroll offsets a workspace's views showed that neither the daemon nor the window keeps:
/// each screen's strip, row and scroll area offsets, each pane's tab strip scroll and the screen
/// bar's. Its window keeps it in memory when it unmounts the workspace
/// (`WindowController.releaseParked`) and the next mount applies it before its first frame commits,
/// so an unmount loses nothing the person can see. The tree, tabs and titles come
/// back from the daemon's store; the selected tabs and the focused pane stay in the window
/// (`TabSelectionMemory`, the focus machine's remembered pane), which an unmount does not touch.
///
/// Chrome keeps the same for a discarded tab: the `NavigationEntry`'s `PageState` holds the scroll
/// offset (content/public/browser/navigation_entry.h), and the reloaded renderer restores it from
/// its `HistoryItem` view state before the first paint
/// (third_party/blink/renderer/core/loader/history_item.h).
///
/// Budget: one entry per screen with a camera, per overflowing row column and scroll area, and per
/// scrolled tab strip; a pane or screen at its start has none. At most 2 KB held for 12 panes with
/// every offset set, counting its id strings as its own (`WorkspaceViewRecordTests`).
public nonisolated struct WorkspaceViewRecord: Hashable, Sendable {
    /// Each screen's offsets, by screen; a screen with none has no entry.
    public var screens: [LayoutScreenID: LayoutScreenScroll]
    /// Each scrolled tab strip's offset, by pane.
    public var tabStrips: [LayoutPaneID: CGFloat]
    /// The screen bar's scroll; nil at its start.
    public var screenBar: CGFloat?

    public init(screens: [LayoutScreenID: LayoutScreenScroll] = [:], tabStrips: [LayoutPaneID: CGFloat] = [:], screenBar: CGFloat? = nil) {
        self.screens = screens
        self.tabStrips = tabStrips
        self.screenBar = screenBar
    }

    /// The offsets it holds (the budget's unit).
    public var entryCount: Int {
        screens.values.reduce(0) { $0 + ($1.strip == nil ? 0 : 1) + $1.rows.count + $1.areas.count } + tabStrips.count + (screenBar == nil ? 0 : 1)
    }

    /// The record of a tab strip's offset: nil at the start (the strip's own default), so a record
    /// of panes nobody scrolled stays empty.
    public static func stripOffset(_ offset: CGFloat) -> CGFloat? {
        offset > 0.5 ? offset : nil
    }
}
