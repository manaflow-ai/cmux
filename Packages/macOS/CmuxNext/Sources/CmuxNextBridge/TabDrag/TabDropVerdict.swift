public import CmuxNextDesign

/// Why a drop target cannot take the dragged tabs. The zone does not
/// highlight and the drop springs back (`TabDropPreview.highlights`).
public nonisolated enum TabDropRefusal: Hashable, Sendable {
    /// A split of the source pane with every tab it holds, on an owner that
    /// cannot spawn a replacement tab: nothing would be left to split.
    case splitEmptiesPane
    /// A new column before the first one: no daemon command expresses it.
    case columnBeforeFirst
    /// A tab group dropped on a dock edge: groups have no dock move yet.
    case groupDock
    /// The surface refused it with this localized reason
    /// (`TabDropProposal.refusedReason`).
    case surface(String)
}

/// What a surface's proposal means for this drag (tab-dnd, Lawrence
/// 2026-10-04: every point shows a preview, and the drop does exactly what
/// the preview shows).
public nonisolated enum TabDropVerdict: Hashable, Sendable {
    /// The drop runs the proposal.
    case accept
    /// The proposal is the tabs' own place: the preview shows it, and the
    /// drop changes nothing.
    case stay
    /// The proposal cannot run: nothing highlights, and the drop springs
    /// back.
    case refuse(TabDropRefusal)
}

nonisolated extension TabDragResolver {
    /// The verdict for `kind`. `accepts` is `verdict == .accept`.
    public static func verdict(_ kind: TabDropKind, context: TabDragContext) -> TabDropVerdict {
        switch kind {
        case .strip(let strip, let index, let group):
            return context.isOwnPlace(strip: strip, index: index, groupID: group) ? .stay : .accept
        case .newSplit(let pane, _):
            let empties = pane == context.sourcePaneID && context.emptiesSourcePane && !context.respawnsOnSplit
            return empties ? .refuse(.splitEmptiesPane) : .accept
        case .newColumn(_, let after):
            return after == nil ? .refuse(.columnBeforeFirst) : .accept
        case .newDock:
            return context.isGroupDrag ? .refuse(.groupDock) : .accept
        case .newWorkspace:
            return .accept
        case .workspace(let id):
            return id == context.sourceWorkspaceID ? .stay : .accept
        }
    }
}
