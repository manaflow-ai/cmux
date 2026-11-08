import AppKit
import CmuxNextDesign
import QuartzCore

// Pin and unpin motion (cmux-ad m70, Lawrence 2026-11-08: "animation when i pin stuff and unpin stuff is not very good.
// like it needs to translate properly from its original position to new position").
//
// On the sidebar document a pinned workspace is an item of the Pinned block (`SidebarItemRowView` in a
// `SidebarRegionView`) and a listed one is a list row (`WorkspaceRowView`): two views in two containers. Before this,
// a pin closed the list row in place and grew a new item out of an empty frame at the block's corner, and an unpin
// dropped the item and faded a new row in at its slot: nothing travelled. Chromium's tab strip moves the same tab view
// (`TabStripLayoutHelper` + `BoundsAnimator`); the sidebar cannot, since the two places are different containers
// with different row classes. So the hand-off is made invisible instead: in the key's turn the arriving view
// starts exactly on the frame the leaving view is drawn on now (its presentation, so a pin mid-flight hands off with
// no jump), the leaving view hides in the same transaction (exactly one copy on screen every frame), and the arriving
// view, its title and the rows between the two slots all move on the rows' one `.move` spring from one begin time,
// from rest (no velocity carried over a retarget). The size and inset change on the same spring and progress as the
// move; the pin glyph is the arriving view's from the first frame.

/// One flight of a pin or an unpin: the view that arrives, where it starts and its title's start offset.
@MainActor
struct SidebarPinFlight {
    /// The pinned item (a pin) or the list row (an unpin).
    let view: NSView
    /// Where it starts, in its superview's coordinates; nil: the rows' move already starts it there (an unpin's row).
    let start: NSRect?
    /// Its title and how far from its own place the title starts (in the title's superview): where the leaving view drew it.
    let title: (view: NSView, offset: CGPoint)?

    func start(_ token: MotionSpring, now: CFTimeInterval) {
        if let start { SidebarDragSpring.fly(view, from: start, token, now: now) }
        if let title { SidebarDragSpring.offset(title.view, by: title.offset, token, now: now) }
    }
}

/// What a pin's leaving view showed in the key's turn (list coordinates, as drawn).
struct SidebarPinFlightSource {
    var frame: NSRect
    /// The title's pen origin, nil when the view draws none.
    var pen: CGPoint?
}

/// The sources the apply running now hands off: the list rows a pin moves into a block and the block items an unpin
/// moves back into the list, by workspace.
struct SidebarPinFlightSources {
    var pins: [WorkspaceID: SidebarPinFlightSource] = [:]
    var unpins: [WorkspaceID: SidebarPinFlightSource] = [:]
    var isEmpty: Bool { pins.isEmpty && unpins.isEmpty }

    /// The unpin source of row `key` (a listed workspace an unpin brings back).
    func unpin(for key: SidebarRowKey) -> SidebarPinFlightSource? {
        if case let .workspace(id) = key { return unpins[id] }
        return nil
    }

    /// Whether row `key` leaves the list for a pinned block (its item takes over in the same frame).
    func pins(_ key: SidebarRowKey) -> Bool {
        if case let .workspace(id) = key { return pins[id] != nil }
        return false
    }
}

extension SidebarListViewComponents {
    /// The workspaces the blocks of `blocks` draw (`SidebarItemInfo.workspace`). O(pinned items).
    func blockWorkspaces(_ blocks: SidebarListBlocks?) -> Set<WorkspaceID> {
        guard let blocks else { return [] }
        return Set(blocks.sections.values.lazy.flatMap(\.items).compactMap { blocks.infos[$0.id]?.workspace })
    }

    /// The workspaces the blocks' items draw now (before an apply changes them). O(pinned items).
    func blockDrawnWorkspaces() -> Set<WorkspaceID> {
        Set(blockRegions.lazy.flatMap(\.itemViews.values).filter { $0.superview != nil }.compactMap(\.info.workspace))
    }

    /// Before an apply's rows change: the views a pin or an unpin hands off, with where each is drawn now. Only the
    /// realized rows and the blocks' items are read (O(realized + pinned)). Empty when the apply does not move rows.
    func pinFlightSources(from old: SidebarLayout, to layout: SidebarLayout, moves: Bool) -> SidebarPinFlightSources {
        var sources = SidebarPinFlightSources()
        guard moves, drag == nil, settling == nil, landing == nil else { return sources }
        let pinned = blockWorkspaces(blocks)
        for (key, view) in rowViews {
            guard case let .workspace(id) = key, layout.row(for: key) == nil, pinned.contains(id), !view.isHidden else { continue }
            sources.pins[id] = source(of: view)
        }
        // A row a pin held in place (`holdsForPin`) until this update's block draws its workspace.
        for (id, view) in pinHolds where pinned.contains(id) && !view.isHidden && sources.pins[id] == nil {
            sources.pins[id] = source(of: view)
        }
        for region in blockRegions {
            for view in region.itemViews.values where view.superview != nil && !view.isHidden {
                guard let id = view.info.workspace, !pinned.contains(id), old.row(for: .workspace(id)) == nil,
                      layout.row(for: .workspace(id)) != nil else { continue }
                sources.unpins[id] = source(of: view)
            }
        }
        return sources
    }

    /// `view`'s frame in the list as drawn now (its and its containers' presentation), with its title's pen origin.
    private func source(of view: NSView) -> SidebarPinFlightSource {
        let frame = drawnFrame(of: view)
        let pen = (view as? any SidebarRenameTitle)?.titlePenOrigin.map { pen in
            CGPoint(x: frame.minX + pen.pointValue.x, y: frame.minY + pen.pointValue.y)
        }
        return SidebarPinFlightSource(frame: frame, pen: pen)
    }

    /// Whether the leaving row `key` is a pin's whose block does not draw the workspace yet: then it stays where it is
    /// drawn (above the rows that close its slot) until the block's item takes over its frame, or for at most
    /// `pinHoldLimit` when no block comes (it then goes at once).
    func holdsForPin(_ key: SidebarRowKey, _ view: SidebarRowView) -> Bool {
        guard case let .workspace(id) = key, drag == nil, settling == nil, landing == nil, !view.isHidden,
              model.workspacePin?.isPinned(id) == true, !blockWorkspaces(blocks).contains(id) else { return false }
        if let held = pinHolds[id], held !== view { releasePinHold(held) }
        pinHolds[id] = view
        view.layer?.zPosition = 1
        // concurrency-allow: asyncAfter only schedules the fallback on the main queue; no thread waits for it
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pinHoldLimit) { [weak self, weak view] in
            guard let self, let view, self.pinHolds[id] === view else { return }
            self.pinHolds[id] = nil
            self.releasePinHold(view)
        }
        return true
    }

    /// Before an apply's rows change: the block items an unpin takes out while the list does not draw the workspace's
    /// row yet stay where they are drawn (their region holds them) until the row's update; the row then starts on the
    /// item's frame. At most `pinHoldLimit`, then they go at once.
    func holdUnpinnedItems(to layout: SidebarLayout) {
        guard drag == nil, settling == nil, landing == nil, let pin = model.workspacePin else { return }
        let pinned = blockWorkspaces(blocks)
        for region in blockRegions {
            for view in region.itemViews.values where view.superview != nil && !view.isHidden {
                guard let id = view.info.workspace, !pinned.contains(id), !region.heldWorkspaces.contains(id),
                      layout.row(for: .workspace(id)) == nil, !pin.isPinned(id) else { continue }
                region.heldWorkspaces.insert(id)
                view.layer?.zPosition = 1
                // concurrency-allow: asyncAfter only schedules the fallback on the main queue; no thread waits for it
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.pinHoldLimit) { [weak region] in
                    guard let region, region.heldWorkspaces.contains(id) else { return }
                    region.releaseHeld(id)
                }
            }
        }
    }

    /// After an apply: the held items whose row now shows (it flew from them) go.
    func releaseUnpinnedItems(_ ids: some Sequence<WorkspaceID>) {
        for id in ids {
            for region in blockRegions where region.heldWorkspaces.contains(id) { region.releaseHeld(id) }
        }
    }

    /// How long a pin's row waits for its block (the block's update follows the rows' within a frame or two).
    static var pinHoldLimit: TimeInterval { 0.25 }

    /// After an apply: a held row whose pin no longer waits (its block drew it, or the pin was undone) goes.
    func settlePinHolds() {
        let drawn = blockWorkspaces(blocks)
        for (id, view) in pinHolds where drawn.contains(id) || model.workspacePin?.isPinned(id) != true {
            pinHolds[id] = nil
            releasePinHold(view)
        }
    }

    private func releasePinHold(_ view: SidebarRowView) {
        view.layer?.zPosition = 0
        recycle(view)
    }

    /// `view`'s frame in the list's coordinates where the screen shows it now: its model frame moved by what the
    /// running animations add to it and to each container up to the list, evaluated as the render server does
    /// (`MotionPath`, exact at `now` with no commit needed); a layer with an animation the path cannot read falls back
    /// to its presentation.
    func drawnFrame(of view: NSView, now: CFTimeInterval = CACurrentMediaTime()) -> NSRect {
        var frame = convert(view.bounds, from: view)
        var current: NSView? = view
        while let node = current, node !== self {
            if let layer = node.layer {
                let position = MotionPath(layer, "position", now: now)
                if position.isExact {
                    let shown = position.value(at: now)
                    frame.origin.x += shown.x - layer.position.x
                    frame.origin.y += shown.y - layer.position.y
                } else if let shown = layer.presentation() {
                    frame.origin.x += shown.frame.minX - layer.frame.minX
                    frame.origin.y += shown.frame.minY - layer.frame.minY
                }
                if node === view {
                    let size = MotionPath(layer, "bounds.size", now: now)
                    if size.isExact { frame.size = CGSize(width: size.value(at: now).x, height: size.value(at: now).y) }
                }
            }
            current = node.superview
        }
        return frame
    }

    /// The pins' arriving items: each block item that now draws a pinned workspace with a source starts on that source.
    /// The block that holds one draws above the rows and does not clip while it flies (`SidebarPinFlight`).
    func pinFlights(_ sources: SidebarPinFlightSources) -> [SidebarPinFlight] {
        var flights: [SidebarPinFlight] = []
        for (id, source) in sources.pins {
            guard let block = rowViews.values.first(where: { ($0 as? SidebarBlockRowView)?.region.itemView(workspace: id) != nil })
                    as? SidebarBlockRowView,
                  let item = block.region.itemView(workspace: id), let container = item.superview else { continue }
            // The block moves on the same spring from where it is drawn now: the item's start is the source less that.
            let blockShown = drawnFrame(of: block)
            let inBlock = source.frame.offsetBy(dx: -blockShown.minX, dy: -blockShown.minY)
            let start = container.convert(inBlock, from: block)
            block.clipsToBounds = false
            raiseForFlight(block)
            flights.append(SidebarPinFlight(view: item, start: start, title: titleOffset(of: item, from: source)))
        }
        for region in blockRegions { region.flyingWorkspaces = [] }
        return flights
    }

    /// An unpin's arriving list row: it starts on the item's drawn frame, opaque and unclipped; the rows' move carries it
    /// to its slot. Returns its flight (the title's offset).
    func unpinFlight(_ view: SidebarRowView, from source: SidebarPinFlightSource) -> SidebarPinFlight {
        Motion.withoutAnimation {
            view.frame = source.frame
            view.alphaValue = 1
            view.clipsToBounds = false
            view.layoutSubtreeIfNeeded()
        }
        raiseForFlight(view)
        return SidebarPinFlight(view: view, start: nil, title: titleOffset(of: view, from: source))
    }

    /// How far `view`'s title must start from its own place so it draws on the leaving view's title: `view` starts on
    /// the source's frame, so its pen starts there plus its own pen origin. The containers share the list's scale and
    /// flip, so the offset is the same in the title's superview.
    private func titleOffset(of view: NSView, from source: SidebarPinFlightSource) -> (view: NSView, offset: CGPoint)? {
        guard let sourcePen = source.pen, let titled = view as? any SidebarRenameTitle, let pen = titled.titlePenOrigin?.pointValue,
              let title = Self.flightTitle(of: view) else { return nil }
        let startPen = CGPoint(x: source.frame.minX + pen.x, y: source.frame.minY + pen.y)
        let offset = CGPoint(x: sourcePen.x - startPen.x, y: sourcePen.y - startPen.y)
        guard abs(offset.x) > 0.25 || abs(offset.y) > 0.25 else { return nil }
        return (title, offset)
    }

    /// The label a row or a pinned item draws its title in.
    static func flightTitle(of view: NSView) -> NSView? {
        if let row = view as? WorkspaceRowView { return row.title }
        if let item = view as? SidebarItemRowView { return item.title }
        return nil
    }

    /// Draws `view` above the rows it crosses while it flies (z position, not a re-add: re-adding a view delays its
    /// first frames, cx-ai79). The move's end puts it back (`landFlights`).
    private func raiseForFlight(_ view: NSView) {
        view.layer?.zPosition = 1
    }

    /// The flights' views draw at their places in the stack again once the move ended.
    static func landFlights(_ flights: [SidebarPinFlight]) {
        for flight in flights {
            flight.view.layer?.zPosition = 0
            if let block = flight.view.enclosingRow { block.layer?.zPosition = 0 }
        }
    }
}

private extension NSView {
    /// The list row this view is in (a block's item is in its block row).
    var enclosingRow: SidebarRowView? {
        var current = superview
        while let node = current {
            if let row = node as? SidebarRowView { return row }
            current = node.superview
        }
        return nil
    }
}
