public import CmuxNextDesign
import CmuxNextLayout

/// Why a drop target cannot take the dragged tabs. The zone does not
/// highlight and the drop springs back (`TabDropPreview.highlights`).
public nonisolated enum TabDropRefusal: Hashable, Sendable {
    /// A new column before the first one: no daemon command expresses it.
    case columnBeforeFirst
    /// A tab group dropped on a dock edge: groups have no dock move yet.
    case groupDock
    /// A new workspace for a tab that stays in its workspace (Home's own tab).
    case staysPut
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
    /// The verdict for `kind`: the tabs' own strip place and their own
    /// workspace stay; a column before the first, a group on a dock and a
    /// new workspace for a tab that stays put are refused (Rust's
    /// `tab_drag_rule_verdict`). A stay when the reducer does not answer:
    /// the drop changes nothing.
    public static func verdict(_ kind: TabDropKind, context: TabDragContext) -> TabDropVerdict {
        let request = Wire.VerdictRequest(kind: Wire.Kind(kind), context: Wire.Context(context))
        let reply = LayoutReducerJSON().call("tab_drag_rule_verdict", request, as: Wire.VerdictReply.self)
        return reply?.tabDropVerdict ?? .stay
    }
}
