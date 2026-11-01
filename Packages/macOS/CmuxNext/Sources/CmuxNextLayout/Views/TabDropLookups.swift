import CoreGraphics

/// One in-process drag's drop-target lookups on one window's layouts (`LayoutRootView.updateTabDrag`'s
/// `lookups`). The App's drop target keeps one for the length of a drag and hands it to every update,
/// so a pointer move over a pane edge computes that edge's split room and final-layout preview (each a
/// full `ScreenGeometry.compute`) once, not on every move. A screen's entries go when anything they
/// read changes: a layout pass (`reconcilePasses`: a layout, a resize, a style change), a row or scroll
/// area offset, the strip scroll, zoom or split sizing. The counts are what the drag's work budget test
/// reads (TabDragWorkTests).
public final class TabDropLookups {
    /// `ScreenContentView.dropTarget` evaluations.
    public internal(set) var targets = 0
    /// Full `ScreenGeometry.compute` passes: a columns screen's split room check and an edge's
    /// final-layout preview.
    public internal(set) var geometryComputes = 0
    /// `navigationFrames` and pane chrome band maps built.
    public internal(set) var frameMaps = 0

    typealias Preview = (newPane: CGRect, resized: [CGRect])
    private struct Key: Hashable {
        var view: ObjectIdentifier
        var pane: PaneID
        var zone: PaneDropZone
        var removing: PaneID?
    }

    /// What a screen's room checks and previews read; any change drops them.
    struct Revision: Equatable {
        var passes: Int
        var size: CGSize
        var scroll: CGFloat
        var rows: [ColumnID: CGFloat]
        var areas: [SplitID: CGFloat]
        var zoomed: Bool
        var evenSizing: Bool
        var style: LayoutStyle
    }

    private var revisions: [ObjectIdentifier: Revision] = [:]
    private var rooms: [Key: DropTarget] = [:]
    private var previews: [Key: Preview?] = [:]
    private var frames: [ObjectIdentifier: [PaneID: CGRect]] = [:]

    public init() {}

    /// Drops `view`'s entries when what they read changed since they were kept.
    func validate(_ view: ScreenContentView) {
        let id = ObjectIdentifier(view)
        let now = Revision(passes: view.reconcilePasses, size: view.bounds.size, scroll: view.scroll.value, rows: view.rowOffsets,
                           areas: view.areaOffsets, zoomed: view.zoomed, evenSizing: view.context.model.splitSizing == .even,
                           style: view.context.style)
        guard revisions[id] != now else { return }
        revisions[id] = now
        rooms = rooms.filter { $0.key.view != id }
        previews = previews.filter { $0.key.view != id }
        frames[id] = nil
    }

    /// `hit` after `view`'s room check (`roomAdjusted`), kept per pane edge.
    func room(_ view: ScreenContentView, _ hit: DropTarget, _ removing: PaneID?) -> DropTarget {
        guard case let .pane(pane, zone) = hit, zone.splitAxis != nil else { return view.roomAdjusted(hit, removing: removing, lookups: self) }
        let key = Key(view: ObjectIdentifier(view), pane: pane, zone: zone, removing: removing)
        if let kept = rooms[key] { return kept }
        let room = view.roomAdjusted(hit, removing: removing, lookups: self)
        rooms[key] = room
        return room
    }

    /// `view`'s final-layout preview of splitting `pane` at `zone`, kept (nil too).
    func preview(_ view: ScreenContentView, _ pane: PaneID, _ zone: PaneDropZone, _ removing: PaneID?) -> Preview? {
        let key = Key(view: ObjectIdentifier(view), pane: pane, zone: zone, removing: removing)
        if let kept = previews[key] { return kept }
        let preview = view.finalLayoutPreview(splitting: pane, zone: zone, removing: removing, lookups: self)
        previews[key] = .some(preview)
        return preview
    }

    /// `view`'s `navigationFrames`, kept.
    func navigationFrames(_ view: ScreenContentView) -> [PaneID: CGRect] {
        let id = ObjectIdentifier(view)
        if let kept = frames[id] { return kept }
        frameMaps += 1
        let built = view.navigationFrames
        frames[id] = built
        return built
    }
}
