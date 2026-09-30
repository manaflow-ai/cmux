public import AppKit
import CmuxNextDesign

/// A sidebar row drag handed to the App when its pointer leaves the sidebar
/// sideways, so the App's window drag can carry it to another window or
/// tear it off into a new one.
public struct SidebarDragHandoff {
    /// The dragged workspaces (in tree order), or a group and its members.
    public var payload: DragPayload
    /// Members of `payload` (the group's workspaces for a group).
    public var workspaceIDs: [WorkspaceID]
    /// The lifted row's frame in screen coordinates.
    public var rowScreenFrame: CGRect
    /// Pointer offset from the row frame's origin (screen space, y up).
    public var grabOffset: CGPoint
    public var screenPoint: CGPoint
    /// Snapshot of the lifted row, for the drag ghost.
    public var image: CGImage?
}

extension SidebarView {
    /// Offered each row drag once its pointer leaves the sidebar sideways.
    /// Return true to take it over: the sidebar ends its own drag at once
    /// (rows reappear in place) and sends no intent. Nil keeps every drag in
    /// the sidebar.
    public var onDragHandoff: ((SidebarDragHandoff) -> Bool)? {
        get { list.onDragHandoff }
        set { list.onDragHandoff = newValue }
    }
}

extension SidebarListView {
    /// Hands `drag` over when the pointer is beyond the sidebar's side
    /// edges. Returns true when the App took it (the drag is then over here).
    func offerHandoff(_ drag: Drag, windowPoint: NSPoint) -> Bool {
        guard let handoff = onDragHandoff, let window, let scroll = enclosingScrollView else { return false }
        let sidebarFrame = scroll.convert(scroll.bounds, to: nil)
        let slack = Metrics.space6
        guard windowPoint.x > sidebarFrame.maxX + slack || windowPoint.x < sidebarFrame.minX - slack else { return false }
        let members: [WorkspaceID]
        switch drag.payload {
        case let .workspaces(ids): members = ids
        case let .group(group): members = model.group(group)?.workspaces.map(\.id) ?? []
        }
        guard !members.isEmpty else { return false }
        let rowFrame = window.convertToScreen(convert(drag.lift.frame, to: nil))
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let offer = SidebarDragHandoff(
            payload: drag.payload, workspaceIDs: members, rowScreenFrame: rowFrame,
            grabOffset: CGPoint(x: screenPoint.x - rowFrame.minX, y: screenPoint.y - rowFrame.minY),
            screenPoint: screenPoint, image: drag.lift.snapshotImage()
        )
        guard handoff(offer) else { return false }
        abandonDrag(drag)
        return true
    }

    /// Ends a handed-off drag without an intent or a landing flight.
    func abandonDrag(_ drag: Drag) {
        stopAutoscroll()
        self.drag = nil
        press?.cancelled = true
        drag.lift.removeFromSuperview()
        suppressed.subtract(drag.hiddenKeys)
        for key in drag.hiddenKeys { rowViews[key]?.alphaValue = 1 }
        reload(animated: true)
        decorations.setPill(activePillFrame(in: displayed), animated: false)
    }
}

extension NSView {
    /// The view's layer tree rendered at its backing scale.
    func snapshotImage() -> CGImage? {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return context.makeImage()
    }
}
