import AppKit

/// One internal drag reorder in the workspace list (`SidebarListView.Drag`):
/// the lifted rows, the card, and the slot or row the drop would take.
final class SidebarListDrag {
    let payload: DragPayload
    let grabbedKey: SidebarRowKey
    /// Keys hidden while dragging (the lifted rows).
    let hiddenKeys: Set<SidebarRowKey>
    let grabOffsetY: CGFloat
    /// Press x from the row's leading edge; with `grabOffsetY`, the
    /// point a window-drag hand-off keeps under the pointer.
    var grabOffsetX: CGFloat = 0
    let gapHeight: CGFloat
    let lift: DragLiftView
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
    /// The last pointer y in the list and the drag's vertical direction.
    var lastY: CGFloat = 0, movingUp = false
    /// The last drop probe (debug.sidebar_rows "drop"): the card edge that
    /// decided, the row it hit in the base layout and where in that row.
    var probe: SidebarDropProbe?
    init(payload: DragPayload, grabbedKey: SidebarRowKey, hiddenKeys: Set<SidebarRowKey>, grabOffsetY: CGFloat, gapHeight: CGFloat, lift: DragLiftView, target: DropTarget?) {
        self.payload = payload
        self.grabbedKey = grabbedKey
        self.hiddenKeys = hiddenKeys
        self.grabOffsetY = grabOffsetY
        self.gapHeight = gapHeight
        self.lift = lift
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
        let centreY = DropResolver.baseY(forDisplayY: card.midY, gapY: displayed.gapY, gapHeight: displayed.gapShift)
        let leadingY = DropResolver.baseY(forDisplayY: leading, gapY: displayed.gapY, gapHeight: displayed.gapShift)
        guard let resolved = DropResolver.resolveDrag(centreY: centreY, leadingY: leadingY, payload: payload, base: base,
                                                      sections: sections, ungroupedFirst: ungroupedFirst) else {
            noteProbe(nil, card: card, centreY: centreY, leadingY: leadingY, base: base)
            return nil
        }
        noteProbe(resolved.probe, card: card, centreY: centreY, leadingY: leadingY, base: base, target: resolved.target)
        return .some(resolved.target)
    }

    /// Records the drop probe (debug.sidebar_rows "drop"): the card point
    /// that decided (`used`, nil when none could), its row and zone.
    private func noteProbe(_ used: DropResolver.DragProbe?, card: CGRect, centreY: CGFloat?, leadingY: CGFloat?, base: SidebarLayout,
                   target: DropTarget? = nil) {
        let edge = used == .centre ? "centre" : (movingUp ? "top" : "bottom")
        let displayY = used == .centre ? card.midY : (movingUp ? card.minY : card.maxY)
        guard let used, let y = used == .centre ? centreY : leadingY else {
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
        }
    }
}
