import AppKit

/// One internal drag reorder in the workspace list (`SidebarListView.Drag`):
/// the lifted rows, the card, and the slot or row the drop would take.
final class SidebarListDrag {
    let payload: DragPayload
    let grabbedKey: SidebarRowKey
    /// The workspace of the group's one row this group drag was lifted from (`SidebarLayout+SoleMember`): in the
    /// sidebar the row moves its group, out of it (a pane, another window) it is that workspace, as its member row was.
    var standingWorkspace: WorkspaceID?
    /// Keys hidden while dragging (the lifted rows).
    let hiddenKeys: Set<SidebarRowKey>
    var grabOffsetY: CGFloat
    /// Press x from the row's leading edge; with `grabOffsetY`, the
    /// point a window-drag hand-off keeps under the pointer.
    var grabOffsetX: CGFloat = 0
    let gapHeight: CGFloat
    let lift: DragLiftView
    /// A workspace card's head row height (`head`, its first lifted row):
    /// the card may carry more rows below it, but drops resolve against the
    /// head alone, as for a one-row card, so its centre can still reach a
    /// row's onto band (cx-ikxz).
    var headHeight: CGFloat?
    /// A dragged group's drag (`SidebarGroupDrag`): the frozen base, the capped card and its slot. Nil for every
    /// other drag; a group drag always has one (`SidebarListView.beginGroupDrag`).
    var group: SidebarGroupDrag?
    /// The card as drops see it: the head row of a workspace card.
    var probeCard: CGRect {
        var card = lift.frame
        if let headHeight { card.size.height = min(card.height, headHeight) }
        return card
    }
    /// The top section the rows would join (drop-to-pin), while the
    /// pointer is over the band above the list; the list keeps its order.
    var pinTarget: SidebarRegionDrop?
    var target: DropTarget? {
        didSet { if case let .position(position)? = target { lastPosition = position } }
    }
    /// The last slot: while the card is over a row's middle
    /// (`ontoWorkspace`), the list keeps showing it, so nothing moves.
    private(set) var lastPosition: DropPosition?
    var lastWindowPoint: NSPoint = .zero
    /// A workspace drag's onto band (sticky edges).
    var band = SidebarGroupBand()
    /// Where the dragged workspaces started (what Cmd-Z puts them back to).
    var origin: DropPosition?
    /// The row a drop grouped with: its new group renames in place once the drag has landed and the rows have settled.
    var renameOnLand: WorkspaceID?
    /// The last pointer y in the list and the drag's vertical direction.
    var lastY: CGFloat = 0, movingUp = false
    /// The sidebar document's drag (sidebar-v2 S5): the moved items, the
    /// acceptance table from the drag's one `drag_begin`, the geometry built
    /// once over the list without the dragged rows, and the move a drop makes.
    var docItems: [String]?
    var docAcceptance: [String: SidebarDocAcceptance] = [:]
    var docGeometry: (SidebarDragGeometry, [String: SidebarRow])?
    /// The list structure (`SidebarModel.sectionsRevision`) `docGeometry` was built for.
    var geometryRevision: UInt64 = 0
    var docTarget: SidebarDocTarget? {
        didSet { if docTarget != oldValue { docTargetChangedUp = movingUp } }
    }
    /// Whether the drag was moving up when `docTarget` last changed: a move the other way turns back (`SidebarDragGeometry.edgeY`).
    private(set) var docTargetChangedUp: Bool?
    /// The pointer is beside the sidebar with an item the App removes there (`holdsDragOut`): a release removes it.
    var removesOnDrop = false
    /// A drag of an item a list block draws (a Pinned or custom tile or row): its section and item.
    var tileSource: (section: String, item: LayoutItemID)?
    /// The region whose tile holds the press (it keeps the view until the release).
    weak var tileRegion: SidebarRegionView?
    /// Where the drop opens a gap in a block (a tile section): the section and the index among its items.
    var blockTarget: SidebarBlockGap?
    /// Each block's laid-out items without the dragged one, at the drag's begin (its hit test's base).
    var blockBases: [String: SidebarRegionLayout] = [:]
    /// The lifted card's shape as a list row (list coordinates; x and size):
    /// a row drag's own row, a tile drag's row look. The card morphs to it
    /// over the list and to a slot's shape over a block (`SidebarListView.morphLift`).
    var restFrame: CGRect = .zero
    /// The card is shaped as its list row; else as a block slot, and it follows the pointer on both axes.
    var restShaped = true
    /// One card drags only: a group keeps its block shape.
    var morphs = false
    /// The last drop probe (debug.sidebar_rows "drop"): the card edge that
    /// decided, the row it hit in the base layout and where in that row.
    var probe: SidebarDropProbe?
    /// The dropped item's real views, invisible under the landing card until it is gone.
    var heldViews: [NSView] = []
    /// The list rows among `heldViews`, suppressed until the card is gone (a reload under the flight does not fade them in).
    var heldKeys: Set<SidebarRowKey> = []
    /// The model shows the drop (`landSettled`): until the card is gone, a later reload (the blocks reach the
    /// list after the rows) retargets it to the dropped item's frame then and holds the item's new views.
    var landsOnModel = false
    /// The landing's completion, kept for a retarget (only the last landing call's completion runs).
    var landingThen: (@MainActor () -> Void)?
    init(payload: DragPayload, grabbedKey: SidebarRowKey, hiddenKeys: Set<SidebarRowKey>, grabOffsetY: CGFloat, gapHeight: CGFloat, lift: DragLiftView, head: CGFloat? = nil,
         target: DropTarget?) {
        self.payload = payload
        self.grabbedKey = grabbedKey
        self.hiddenKeys = hiddenKeys
        self.grabOffsetY = grabOffsetY
        self.gapHeight = gapHeight
        self.lift = lift
        if case .workspaces = payload { headHeight = head }
        self.target = target
        if case let .position(position)? = target { lastPosition = position }
        origin = lastPosition
    }
    /// The drop for the card at `card` (list coordinates, as drawn over
    /// `displayed`), or nil to keep the last target; records the probe.
    /// Spec 1780d02: the card's centre decides over a loose row, the leading
    /// edge elsewhere (DropResolver.resolveDrag).
    func resolve(card: CGRect, displayed: SidebarLayout, base: SidebarLayout, sections: [SidebarSection],
                 ungroupedFirst: Bool) -> DropTarget?? {
        let leading = movingUp ? card.minY : card.maxY
        guard let resolved = DropResolver.resolveDrag(centreY: card.midY, leadingY: leading, gapY: displayed.gapY, gapHeight: displayed.gapShift,
                                                      payload: payload, base: base, sections: sections, ungroupedFirst: ungroupedFirst) else {
            noteProbe(nil, card: card, displayed: displayed, base: base)
            return nil
        }
        noteProbe(resolved.probe, card: card, displayed: displayed, base: base, target: resolved.target)
        return .some(resolved.target)
    }

    /// Records the drop probe (debug.sidebar_rows "drop"): the card point
    /// that decided (`used`, nil when none could), its row and zone.
    private func noteProbe(_ used: DropResolver.DragProbe?, card: CGRect, displayed: SidebarLayout, base: SidebarLayout,
                   target: DropTarget? = nil) {
        let edge = used == .centre ? "centre" : (movingUp ? "top" : "bottom")
        let displayY = used == .centre ? card.midY : (movingUp ? card.minY : card.maxY)
        guard used != nil, let y = DropResolver.baseY(forDisplayY: displayY, gapY: displayed.gapY, gapHeight: displayed.gapShift) else {
            probe = SidebarDropProbe(edge: edge, displayY: displayY, target: self.target.map { String(describing: $0) })
            return
        }
        let hit = base.row(at: y)
        probe = SidebarDropProbe(edge: edge, displayY: displayY, baseY: y, row: hit.map { String(describing: $0.key) },
                                 fraction: hit.map { $0.height > 0 ? (y - $0.y) / $0.height : 0 },
                                 target: target.map { String(describing: $0) })
    }

    @MainActor func isValid(in model: SidebarModel) -> Bool {
        switch payload {
        case let .workspaces(ids): ids.allSatisfy { model.workspace($0) != nil }
        case let .group(group): model.group(group) != nil
        case let .item(id): model.sections.contains { $0.nodes.contains { $0.listedItems.contains { $0.id == id } } }
            || (tileSource.flatMap { model.layout.section(LayoutSectionID($0.section)) }?.items.contains { $0.id.rawValue == id } ?? false)
        }
    }
}
