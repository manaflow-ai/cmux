import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout

/// What a requested split of a shown pane does, decided from the live layout
/// geometry before any daemon command (`SplitRoom`). Every split entry point
/// (split actions, tab and tab group moves, drops) goes through
/// `AppServices.splitRoom`, so they refuse or reroute the same way.
enum SplitRoomDecision {
    /// Split in place.
    case split
    /// Columns screen with no room across: open a new column instead.
    /// `afterColumn` places a moved tab; `spawnAnchor` is the pane a new
    /// terminal column opens right of.
    case newColumn(afterColumn: DaemonColumnID?, spawnAnchor: DaemonPaneID)
    /// No room; the localized reason for the caller to report.
    case refused(String)
}

extension AppServices {
    /// Applies the sizing a move that splits `pane` at `edge` lands with, once it landed: the ratios its
    /// drop target previewed (`LayoutModel.dropSizingChanges`: `layout.splitSizing` as a keyboard split
    /// does, #22287, and the close sizing of `emptied`, the pane the move closes). Computed now.
    /// The returned closure sends them once, however many of the move's settle points call it.
    func splitSizing(for pane: PaneModel, edge: PaneEdge, emptying emptied: PaneModel?) -> @MainActor () -> Void {
        guard let controller = paneController(for: pane), let content = controller.workspace else { return {} }
        let changes = content.layoutModel.dropSizingChanges(splitting: controller.layoutPaneID, zone: edge.dropZone,
                                                            removing: emptied.flatMap { $0 === pane ? nil : content.handles.paneIDs[$0.handle] })
        let sent = SizingSent()
        return { [weak content] in
            guard !sent.value else { return }
            sent.value = true
            content?.layoutModel.applySplitSizing(changes)
        }
    }

    /// The decision for splitting `pane` on `edge`. `source` is the pane a moved tab leaves; when that
    /// was its only tab the pane disappears in the same step, which frees room. The chat dock splits only `growsChatDock`
    /// (Split Down, #29848). A pane no window shows (a background workspace driven from the CLI) always splits.
    func splitRoom(for pane: PaneModel, edge: PaneEdge, movingFrom source: PaneModel? = nil, growsChatDock: Bool = false) -> SplitRoomDecision {
        guard let controller = paneController(for: pane), let content = controller.workspace else { return .split }
        let layoutPane = controller.layoutPaneID
        if !growsChatDock, ChatDockRules.isChatDock(pane, services: self) { return .refused(RefusalStrings.chatDockCannotSplit) }
        let axis = edge.splitAxis
        let removing = source.flatMap { source -> LayoutPaneID? in
            guard source !== pane, source.tabs.count == 1 else { return nil }
            return content.handles.paneIDs[source.handle]
        }
        switch content.layoutView.splitPlacement(splitting: layoutPane, axis: axis, removing: removing) {
        case .split:
            return .split
        case .refused(.notEnoughRoom):
            return .refused(RefusalStrings.notEnoughRoomToSplit)
        case .newColumn:
            let columns = content.layoutModel.screen(containing: layoutPane)?.layout.columns ?? []
            guard let index = columns.firstIndex(where: { $0.root.contains(layoutPane) }) else { return .split }
            // A leading-edge request goes after the previous column; before
            // the first column there is no slot, so it goes right.
            if edge == .left, index > 0, let previous = columns[index - 1].root.panes.last,
               let anchor = content.handles.panes[previous] {
                return .newColumn(afterColumn: content.handles.columns[columns[index - 1].id], spawnAnchor: anchor)
            }
            return .newColumn(afterColumn: content.handles.columns[columns[index].id], spawnAnchor: pane.handle)
        }
    }

    /// The daemon handle of the strip column holding `pane`, or nil when no shown screen lays it out in columns.
    func columnHandle(containing pane: PaneModel) -> DaemonColumnID? {
        guard let controller = paneController(for: pane), let content = controller.workspace else { return nil }
        let layoutPane = controller.layoutPaneID
        guard let column = content.layoutModel.screen(containing: layoutPane)?.layout.columns.first(where: { $0.root.contains(layoutPane) })
        else { return nil }
        return content.handles.columns[column.id]
    }

    /// The ONE rule for a split that opens a new tool (Split Right/Down/Left/Up and Split Browser
    /// Right/Down, from the chat header's Terminal and Browser buttons, the palette, menus,
    /// shortcuts and the CLI) (cx-yihq). A person's split from the docked agent chat opens the tool
    /// as a tab in the scrolling strip, as New Terminal and New Browser do there (cx-ic0); a script's
    /// split there is refused, so its result stays predictable; Split Down splits in the dock, as classic Cmd-Shift-D (#29848).
    /// From Home's pinned dock alone
    /// (`pinned-dock-alone-v1`), which has no strip, a person's split opens the tool in a new column
    /// right of the dock, as New Tab does there (Lawrence 2026-10-20: "Command-D in home does not
    /// work"). Elsewhere it splits when the pane has room, and is refused when it has none: a split
    /// never opens a column (column-sizing.md).
    func toolSplit(from pane: PaneModel, edge: PaneEdge, byPerson: Bool) -> ToolSplitDecision {
        let growsChatDock = edge == .bottom && ChatDockRules.splitsDownInDock(pane, services: self)
        if !growsChatDock, byPerson, let route = chatDockRoute(for: pane) { return route }
        switch splitRoom(for: pane, edge: edge, growsChatDock: growsChatDock) {
        case .split: return .split
        case .refused(let reason): return .refused(reason)
        case .newColumn: return .refused(RefusalStrings.columnTooNarrowToSplit)
        }
    }

    /// Where a tool opened from `pane` goes when `pane` is the chat dock: a tab in the strip pane, or
    /// a new column beside Home's pinned dock alone; else nil. A chat dock with nowhere to send it (a
    /// zoomed screen, a daemon without dock roles) gives nil, and `splitRoom` then refuses with
    /// `chatDockCannotSplit`.
    private func chatDockRoute(for pane: PaneModel) -> ToolSplitDecision? {
        guard ChatDockRules.isChatDock(pane, services: self), let controller = paneController(for: pane) else { return nil }
        switch ChatColumnPlacement.resolve(from: controller, services: self) {
        case .tab(let target): return controller.workspace?.panes[target].map { .tab(in: $0) }
        case .besideDock: return .besideDock(controller)
        case .here, .dockChat: return nil
        }
    }

    /// The width of a new column next to `pane`, from every path that opens one; no column there
    /// resizes (R3b). `source` is the pane a moved tab leaves.
    func newColumnWidth(nextTo pane: PaneModel, movingFrom source: PaneModel? = nil) -> Double {
        guard let controller = paneController(for: pane), let content = controller.workspace else {
            return DesignSettings.shared.defaultColumnWidth
        }
        // A pane whose only tab moves out closes, even the anchor itself.
        let removing = source.flatMap { $0.tabs.count == 1 ? content.handles.paneIDs[$0.handle] : nil }
        return content.layoutModel.newColumnWidth(nextTo: controller.layoutPaneID, removing: removing)
    }
}

/// What a split that opens a new tool does (`AppServices.toolSplit`).
enum ToolSplitDecision {
    /// Split the pane in place.
    case split
    /// Open the tool as a tab in this strip pane (the pane was the chat dock).
    case tab(in: PaneController)
    /// Open the tool in a new column right of this pane: Home's pinned chat dock alone, which takes
    /// no tabs and has no strip beside it (`pinned-dock-alone-v1`).
    case besideDock(PaneController)
    /// No split; the localized reason for the caller to report.
    case refused(String)
}

/// Whether a move's split sizing went out (`AppServices.splitSizing`).
private final class SizingSent {
    var value = false
}
