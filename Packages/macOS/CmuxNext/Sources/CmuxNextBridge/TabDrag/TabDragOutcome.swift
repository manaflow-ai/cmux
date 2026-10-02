public import CmuxNextDesign
public import CoreGraphics
public import Foundation

/// How a tab drag ends. The App maps each case to exactly one daemon
/// command (plans/cmux-next/REWRITE.md "Tab drag").
public nonisolated enum TabDragOutcome: Hashable, Sendable {
    /// Into a tab strip at `index` (final display index), joining `groupID`.
    case strip(stripID: UUID, index: Int, groupID: String?)
    /// New pane on `edge` of the layout pane `paneID`.
    case newSplit(paneID: String, edge: TabDropEdge)
    /// New strip column on `screenID` after `afterColumnID`.
    case newColumn(screenID: String, afterColumnID: String)
    /// New workspace at root `index`, inside `groupID` when non-nil.
    case newWorkspace(groupID: String?, index: Int?)
    /// Into an existing workspace.
    case workspace(id: String)
    /// Released outside every window: new workspace in a new window whose
    /// tab strip sits under `screenPoint`.
    case tearOff(screenPoint: CGPoint)
    /// Released outside every window while dragging everything the source
    /// workspace holds, the only workspace of its window: the source window
    /// moves under the pointer instead (Chrome's single-tab window drag).
    /// No daemon command.
    case moveWindow(screenPoint: CGPoint)
    /// Released outside every window while dragging everything the source
    /// workspace holds, whose window lists other workspaces too: the
    /// workspace itself moves to a new window under the pointer. No daemon
    /// command (window membership is frontend-local).
    case moveWorkspaceToNewWindow(screenPoint: CGPoint)
    /// Dropped on a sidebar gap while dragging everything the source
    /// workspace holds: the workspace itself moves to that slot (root
    /// `index`, inside `groupID` when non-nil) in the drop window, instead
    /// of a new workspace next to an emptied one.
    case moveWorkspace(groupID: String?, index: Int?)
    /// No valid target: spring back to the origin.
    case cancel
}

/// What the resolver needs to know about the drag's source.
public nonisolated struct TabDragContext: Hashable, Sendable {
    /// Layout pane id (`PaneModel.id`) of the source pane.
    public var sourcePaneID: String
    /// Tabs in the source pane, including the dragged ones.
    public var sourcePaneTabCount: Int
    public var sourceWorkspaceID: String
    /// Tabs in the whole source workspace, including the dragged ones.
    public var sourceWorkspaceTabCount: Int
    /// Tabs being dragged (1, or a group's member count).
    public var draggedTabCount: Int
    /// Workspaces the source window lists (1 when it shows only this one).
    public var sourceWindowWorkspaceCount: Int
    /// The source strip (`TabStripModel.stripID`) and the dragged tab's (or
    /// group's first tab's) index in its display order; nil for workspace drags.
    public var sourceStripID: UUID?
    public var sourceIndex: Int?
    /// The tab group the dragged tab is in (nil: none, or a group drag).
    public var sourceGroupID: String?

    public init(sourcePaneID: String, sourcePaneTabCount: Int, sourceWorkspaceID: String,
                sourceWorkspaceTabCount: Int, draggedTabCount: Int, sourceWindowWorkspaceCount: Int = 1,
                sourceStripID: UUID? = nil, sourceIndex: Int? = nil, sourceGroupID: String? = nil) {
        self.sourcePaneID = sourcePaneID
        self.sourcePaneTabCount = sourcePaneTabCount
        self.sourceWorkspaceID = sourceWorkspaceID
        self.sourceWorkspaceTabCount = sourceWorkspaceTabCount
        self.draggedTabCount = draggedTabCount
        self.sourceWindowWorkspaceCount = sourceWindowWorkspaceCount
        self.sourceStripID = sourceStripID
        self.sourceIndex = sourceIndex
        self.sourceGroupID = sourceGroupID
    }

    /// Whether a strip drop at final `index` (clamped to the strip without
    /// the dragged tabs) joining `groupID` leaves the tabs where they are.
    func isOwnPlace(strip: UUID, index: Int, groupID: String?) -> Bool {
        guard strip == sourceStripID, let sourceIndex else { return false }
        let final = min(max(index, 0), max(0, sourcePaneTabCount - draggedTabCount))
        return final == sourceIndex && groupID == sourceGroupID
    }

    /// The drag carries every tab of its pane: the pane closes when they leave.
    var emptiesSourcePane: Bool { draggedTabCount >= sourcePaneTabCount }
    /// The drag carries every tab of its workspace (the last tab of the last
    /// pane): the workspace moves with it, or closes once they land in
    /// another workspace (coordinator decision 2026-09-30).
    public var emptiesSourceWorkspace: Bool { draggedTabCount >= sourceWorkspaceTabCount }
}

/// Pure outcome resolution from drop-target proposals. The session asks
/// surfaces in priority order (sidebar, strips, layout) and takes the first
/// proposal `accepts` allows; the others get `dropExited`.
public nonisolated enum TabDragResolver {
    /// False for proposals that would be a no-op or break the layout:
    /// - splitting the source pane with every tab it holds (the pane would
    ///   close, leaving nothing to split; daemons reject the swap too),
    /// - moving into the workspace the tabs already live in,
    /// - a column before the first one (no daemon command expresses it).
    public static func accepts(_ kind: TabDropKind, context: TabDragContext) -> Bool {
        switch kind {
        case .strip:
            return true
        case .newSplit(let pane, _):
            return !(pane == context.sourcePaneID && context.emptiesSourcePane)
        case .newColumn(_, let after):
            return after != nil
        case .newWorkspace:
            return true
        case .workspace(let id):
            return id != context.sourceWorkspaceID
        }
    }

    /// Index of the winning proposal: the first non-nil accepted one.
    public static func winner(_ proposals: [TabDropProposal?], context: TabDragContext) -> Int? {
        proposals.firstIndex { proposal in
            proposal.map { accepts($0.kind, context: context) } ?? false
        }
    }

    /// The outcome for the winning proposal. `insideWindow` is false when
    /// the pointer is outside every app window (tear-off).
    public static func outcome(for proposal: TabDropProposal?, insideWindow: Bool, screenPoint: CGPoint,
                               context: TabDragContext) -> TabDragOutcome {
        guard insideWindow else {
            guard context.emptiesSourceWorkspace else { return .tearOff(screenPoint: screenPoint) }
            return context.sourceWindowWorkspaceCount <= 1 ? .moveWindow(screenPoint: screenPoint)
                : .moveWorkspaceToNewWindow(screenPoint: screenPoint)
        }
        guard let proposal, accepts(proposal.kind, context: context) else { return .cancel }
        switch proposal.kind {
        case .strip(let stripID, let index, let groupID):
            // The tab's own place (its pane's center when it is the last or
            // only tab, or its own slot): no operation, it springs back.
            if context.isOwnPlace(strip: stripID, index: index, groupID: groupID) { return .cancel }
            return .strip(stripID: stripID, index: index, groupID: groupID)
        case .newSplit(let pane, let edge):
            return .newSplit(paneID: pane, edge: edge)
        case .newColumn(let screen, let after):
            guard let after else { return .cancel }
            return .newColumn(screenID: screen, afterColumnID: after)
        case .newWorkspace(let group, let index):
            let slot = index < 0 ? nil : index
            return context.emptiesSourceWorkspace ? .moveWorkspace(groupID: group, index: slot) : .newWorkspace(groupID: group, index: slot)
        case .workspace(let id):
            return .workspace(id: id)
        }
    }
}
