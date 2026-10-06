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
    }
    @MainActor func isValid(in model: SidebarModel) -> Bool {
        switch payload {
        case let .workspaces(ids): ids.allSatisfy { model.workspace($0) != nil }
        case let .group(group): model.group(group) != nil
        }
    }
}
