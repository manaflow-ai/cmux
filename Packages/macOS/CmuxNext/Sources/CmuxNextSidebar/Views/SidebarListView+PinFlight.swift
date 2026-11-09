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
// with different row classes. So the hand-off is made invisible instead: the arriving view starts exactly on the
// frame the leaving view is drawn on at the move's begin (its path evaluated at that instant, so a pin mid-flight
// hands off with no jump), the leaving view hides in the same transaction (exactly one copy on screen every frame),
// and the arriving view, its title and the rows between the two slots all move on the rows' one `.move` spring from
// that one begin time, from rest (no velocity carried over a retarget). The begin is the first frame that can show
// the move (`SidebarPinFlight.begin`), as Chromium starts an animation at the frame it first draws in: the first frame
// shows the workspace where it was, not already moved. The size and inset change on the same spring and progress as
// the move; the pin glyph is the arriving view's from the first frame.

/// One flight of a pin or an unpin: the view that arrives, where it starts and its title's start offset.
@MainActor
struct SidebarPinFlight {
    /// The pinned item (a pin) or the list row (an unpin).
    let view: NSView
    /// Where it starts at a media time (the move's begin), in its superview's coordinates.
    let start: @MainActor (CFTimeInterval) -> NSRect
    /// Its title and how far from its own place the title starts (in the title's superview): where the leaving view drew it.
    let title: (view: NSView, offset: CGPoint)?
    /// A glyph the arriving view draws and the leaving one did not (a pinned item's pin): it fades in on the move.
    var glyph: NSView?
    /// A glyph the leaving view drew and the arriving one does not (an unpinned item's pin): a copy rides the arriving
    /// view from the leaving one's place and fades out on the move; the move's end removes it (`landFlights`).
    var leavingGlyph: NSView?
    /// A flying item's flight serial (`raiseForFlight`): its end lands the item only while no newer flight raised it.
    var serial: Int?
    /// The parts of a block that opens with this pin other than the flying item (its section header): the block itself
    /// shows at once so the item never fades, and these fade in on the move instead.
    var revealed: [NSView] = []

    /// Starts the flight at `now`, the move's one begin time: the view starts where the leaving view is drawn then.
    func start(_ token: MotionSpring, now: CFTimeInterval) {
        SidebarDragSpring.fly(view, from: start(now), token, now: now)
        if let title { SidebarDragSpring.offset(title.view, by: title.offset, token, now: now) }
        if let glyph { SidebarDragSpring.attach(glyph) }
        if let layer = glyph?.layer { SidebarDragSpring.appear(layer, token, now: now) }
        if let leavingGlyph { SidebarDragSpring.attach(leavingGlyph) }
        if let layer = leavingGlyph?.layer { SidebarDragSpring.disappear(layer, token, now: now) }
        // The pin glyph and the title are one line of content: the glyph rides the title's offset on the same spring, so
        // the title never slides onto it (PIN7 films: at an unpin's start the title ran onto the fading pin).
        glyph?.layer?.mask = nil
        if let title {
            for glyph in [glyph, leavingGlyph].compactMap(\.self) { SidebarDragSpring.offset(glyph, by: title.offset, token, now: now) }
            for glyph in [glyph, leavingGlyph].compactMap(\.self) { Self.clipToFill(glyph, riding: title.offset, token, now: now) }
        }
        revealed.forEach(SidebarDragSpring.attach)
        for layer in revealed.compactMap(\.layer) { SidebarDragSpring.appear(layer, token, now: now) }
    }

    /// The pin glyph rides the title, and the two titles are one icon column apart (the item's sits after its pin): on
    /// a pin the glyph starts one column left of its place, left of the item's pill (PIN8 films, SB-PIN), and on an
    /// unpin the item's fading pin ends one column left of the row's title, left of the row's fill (PIN9 films,
    /// SB-UNPIN). The part outside the fill does not draw: the glyph's mask is the fill's sides (the item's pill, the
    /// row's bounds), and it rides the glyph's offset back on the same spring and begin, so it stays on the fill on every
    /// frame and the pin comes out from (or goes under) the fill's edge with the title. The move's end takes it off
    /// (`landFlights`; an unpin's copy goes).
    static func clipToFill(_ glyph: NSView, riding offset: CGPoint, _ token: MotionSpring, now: CFTimeInterval) {
        guard offset.x != 0, let owner = glyph.superview, let layer = glyph.layer else { return }
        let inset = (owner as? SidebarItemRowView)?.fillInset ?? 0, height = owner.bounds.height
        let pill = glyph.convert(NSRect(x: inset, y: 0, width: max(0, owner.bounds.width - inset * 2), height: height), from: owner)
        // Only the sides clip: the glyph's whole height and the item's around it stay (a pin centers on its row).
        let mask = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = CGRect(x: pill.minX, y: -height, width: pill.width, height: layer.bounds.height + height * 2)
        layer.mask = mask
        CATransaction.commit()
        let back = Motion.sidebar.springAnimation(token, "position", from: NSValue(point: CGPoint(x: -offset.x, y: 0)),
                                                  to: NSValue(point: .zero))
        back.isAdditive = true
        back.beginTime = layer.convertTime(now, from: nil)
        back.fillMode = .backwards
        mask.add(back, forKey: "\(SidebarDragSpring.batchKey).pill")
    }

    /// The begin of a move with flights: the begin-frame time of the first frame that can show it, the next vsync of
    /// `view`'s display (`MotionFrameClock`; `clock` for tests). That frame shows the workspace where it was, and the
    /// next one curve(1 refresh), however far into a refresh the change was made. Before it the springs hold their
    /// start (`fillMode` backwards).
    static func begin(in view: NSView, clock: MotionFrameClock? = nil) -> CFTimeInterval {
        (clock ?? MotionFrameClock.forView(view)).firstFrameBegin()
    }
}

/// A flying view's layer background and corner radius before its flight.
struct SidebarFlightGround {
    var color: CGColor?
    var cornerRadius: CGFloat
}

/// Where a pin's leaving view is drawn (list coordinates) over time: its model frame moved by the springs running on
/// it and its containers, read once (`MotionPath`) and evaluated at any instant, so the hand-off is evaluated at the
/// move's begin, not when the apply read it.
struct SidebarPinFlightSource {
    /// The model frame in the list when read.
    var base: NSRect
    /// Each container's (and the view's) position path; nil: a layer the path cannot read, moved by `fallback`.
    var positions: [(path: MotionPath?, fallback: CGPoint)]
    /// The view's size path, when exact.
    var size: MotionPath?
    /// The title's pen origin in the view, nil when the view draws none.
    var pen: CGPoint?
    /// The pin glyph the view draws (a pinned item), its frame in the view (flipped, as both a row and an item are).
    var glyph: (image: NSImage, frame: NSRect, tint: NSColor?)?
    /// How far the view's fill is inset from its sides (`SidebarItemRowView.fillInset`; a row's bounds are its fill).
    var inset: CGFloat = 0

    /// The frame drawn at media time `time`.
    func frame(at time: CFTimeInterval) -> NSRect {
        var frame = base
        for (path, fallback) in positions {
            let offset = path.map { CGPoint(x: $0.value(at: time).x - $0.model.x, y: $0.value(at: time).y - $0.model.y) } ?? fallback
            frame.origin.x += offset.x
            frame.origin.y += offset.y
        }
        if let size {
            let shown = size.value(at: time)
            frame.size = CGSize(width: shown.x, height: shown.y)
        }
        return frame
    }
}

/// The sources the apply running now hands off: the list rows a pin moves into a block and the block items an unpin
/// moves back into the list, by workspace.
/// MOTION LAB (branch motion-lab-nomerge only, never merged): false plays P0, the pin path before the flight (Debug >
/// Motion Lab); every build outside the lab flies.
@MainActor func labPinFlies() -> Bool {
    #if DEBUG || CMUX_BENCH_HOOKS
    DesignSettings.shared.motionLab.pinFlies
    #else
    true
    #endif
}

struct SidebarPinFlightSources {
    var pins: [WorkspaceID: SidebarPinFlightSource] = [:]
    var unpins: [WorkspaceID: SidebarPinFlightSource] = [:]
    /// Rows already closing that a pin's item takes over: they go in the same transaction.
    var closing: [SidebarRowView] = []
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
        guard moves, labPinFlies(), drag == nil, settling == nil, landing == nil else { return sources }
        let pinned = blockWorkspaces(blocks)
        for (key, view) in rowViews {
            guard case let .workspace(id) = key, layout.row(for: key) == nil, pinned.contains(id), !view.isHidden else { continue }
            sources.pins[id] = source(of: view)
            SidebarPerfCounters.add(.pinOneApply)
        }
        // A pin's row an earlier update already closes (the rows reached the list before the blocks: an app that sends
        // them in two updates): the block's item flies from where the closing row is drawn, and the row goes in the
        // same transaction. Nothing waits for the second update.
        for view in subviews.lazy.compactMap({ $0 as? SidebarRowView }) where view.closingEnd != nil && !view.isHidden {
            guard case let .workspace(id) = view.key, rowViews[view.key] == nil, pinned.contains(id), sources.pins[id] == nil
            else { continue }
            sources.pins[id] = source(of: view)
            sources.closing.append(view)
            Self.countRowsFirstGap(CACurrentMediaTime() - view.closingSince)
        }
        for region in blockRegions {
            for view in region.itemViews.values where view.superview != nil && !view.isHidden {
                // The block may still draw it: the app sends an unpin's rows before its blocks (the film's revision 18).
                // A workspace a block draws that gets a new list row moves from the block to the list either way.
                guard let id = view.info.workspace, old.row(for: .workspace(id)) == nil,
                      layout.row(for: .workspace(id)) != nil else { continue }
                sources.unpins[id] = source(of: view)
            }
        }
        return sources
    }

    /// A rows-first pin's gap, from the rows' update to the blocks' (`SidebarPerfCounters.pin_rows_first`).
    static func countRowsFirstGap(_ gap: CFTimeInterval) {
        SidebarPerfCounters.add(.pinRowsFirst)
        SidebarPerfCounters.add(.pinGapMicroseconds, max(0, Int(gap * 1_000_000)))
        if gap > 0.1 { SidebarPerfCounters.add(.pinGapsOver100ms) }
    }

    /// The rows a pin or an unpin flies to: an unpin's list row and the block that takes a pin's item. The apply draws
    /// them even when their slot is out of view, so the flight slides out of view and the workspace never vanishes
    /// (the contract: "Target off-screen: the scroll follows, or the row slides out of view"). O(pins + pinned items).
    func flightTargets(_ sources: SidebarPinFlightSources) -> Set<SidebarRowKey> {
        var keys = Set(sources.unpins.keys.map { SidebarRowKey.workspace($0) })
        guard !sources.pins.isEmpty, let blocks else { return keys }
        for (section, block) in blocks.sections
        where block.items.contains(where: { blocks.infos[$0.id]?.workspace.map { sources.pins[$0] != nil } == true }) {
            keys.insert(.block(section))
        }
        return keys
    }

    /// `view`'s drawn frame in the list over time, with its title's pen origin.
    private func source(of view: NSView) -> SidebarPinFlightSource {
        var source = drawnPath(of: view)
        source.pen = (view as? any SidebarRenameTitle)?.titlePenOrigin?.pointValue
        source.inset = Self.fillInset(of: view)
        if let pin = (view as? SidebarItemRowView)?.pinGlyph as? NSImageView, let image = pin.image {
            source.glyph = (image, view.convert(pin.frame, from: pin.superview), pin.contentTintColor)
        }
        return source
    }

    /// Before an apply's rows change: an item an earlier apply hid because its row flew from it (`hideFlownItems`) shows
    /// again when this apply's list draws no row for its workspace (the unpin was undone): it is the one copy again.
    func showFlownItems(to layout: SidebarLayout) {
        for region in blockRegions where !region.flownOut.isEmpty {
            for id in region.flownOut where layout.row(for: .workspace(id)) == nil {
                region.flownOut.remove(id)
                region.itemView(workspace: id)?.alphaValue = 1
            }
        }
    }

    /// After an apply: an unpinned workspace's item its block still lists (the blocks reach the list in a later update)
    /// hides, as its row flew from it: one copy on screen. The blocks' update takes it out; `showFlownItems` shows it
    /// again if the list stops drawing the row first. No timer: each update decides.
    func hideFlownItems(_ ids: some Sequence<WorkspaceID>) {
        for id in ids {
            for region in blockRegions {
                guard let item = region.itemView(workspace: id) else { continue }
                region.flownOut.insert(id)
                item.alphaValue = 0
            }
        }
    }

    /// `view`'s frame in the list's coordinates where the screen shows it now: its model frame moved by what the
    /// running animations add to it and to each container up to the list, evaluated as the render server does
    /// (`MotionPath`, exact at `now` with no commit needed); a layer with an animation the path cannot read falls back
    /// to its presentation.
    func drawnFrame(of view: NSView, now: CFTimeInterval = CACurrentMediaTime()) -> NSRect {
        drawnPath(of: view, now: now).frame(at: now)
    }

    /// `view`'s drawn frame in the list as a path over time: its model frame and each layer's running animations up to
    /// the list, read once (`drawnFrame` evaluates it now; a flight evaluates it at its begin).
    func drawnPath(of view: NSView, now: CFTimeInterval = CACurrentMediaTime()) -> SidebarPinFlightSource {
        var source = SidebarPinFlightSource(base: convert(view.bounds, from: view), positions: [], size: nil, pen: nil)
        var current: NSView? = view
        while let node = current, node !== self {
            if let layer = node.layer {
                let position = MotionPath(layer, "position", now: now)
                if position.isExact {
                    source.positions.append((position, .zero))
                } else if let shown = layer.presentation() {
                    source.positions.append((nil, CGPoint(x: shown.frame.minX - layer.frame.minX, y: shown.frame.minY - layer.frame.minY)))
                }
                if node === view {
                    let size = MotionPath(layer, "bounds.size", now: now)
                    if size.isExact { source.size = size }
                }
            }
            current = node.superview
        }
        return source
    }

    /// The pins' arriving items: each block item that now draws a pinned workspace with a source starts on that source.
    /// The block that holds one draws above the rows and does not clip while it flies (`SidebarPinFlight`).
    func pinFlights(_ sources: SidebarPinFlightSources) -> [SidebarPinFlight] {
        var flights: [SidebarPinFlight] = []
        for (id, source) in sources.pins {
            guard let block = rowViews.values.first(where: { ($0 as? SidebarBlockRowView)?.region.itemView(workspace: id) != nil })
                    as? SidebarBlockRowView,
                  let item = block.region.itemView(workspace: id), let container = item.superview else { continue }
            // The block moves on the same spring from where it is drawn at the begin (its move is added first): the
            // item's start is the source less that, both at the begin.
            // Fill to fill: the item's pill starts on the row's fill, so its bounds start wider by its inset.
            let widen = source.inset - item.fillInset
            let start: @MainActor (CFTimeInterval) -> NSRect = { [weak self] time in
                guard let self else { return source.frame(at: time).insetBy(dx: widen, dy: 0) }
                let blockShown = drawnFrame(of: block, now: time)
                let inBlock = source.frame(at: time).insetBy(dx: widen, dy: 0).offsetBy(dx: -blockShown.minX, dy: -blockShown.minY)
                return container.convert(inBlock, from: block)
            }
            block.clipsToBounds = false
            raiseForFlight(block)
            let serial = raiseForFlight(item)
            // The flight reads the title's pen and the pin's frame now: a new item lays its parts out on its slot first,
            // as an unpin's row does (`unpinFlight`); the display pass would only do it after the flight read them.
            Motion.withoutAnimation { item.layoutSubtreeIfNeeded() }
            flights.append(SidebarPinFlight(view: item, start: start, title: titleOffset(of: item, from: source), glyph: item.pinGlyph,
                                            serial: serial, revealed: revealOpeningBlock(block, keeping: item)))
        }
        for region in blockRegions { region.flyingWorkspaces = [] }
        return flights
    }

    /// A block that opens with this pin (the first pin creates Pinned) would fade in, and its flying item with it: the
    /// item must translate, opaque. The block shows at once instead; its other parts (the section header, any other item)
    /// fade in on the move (`SidebarPinFlight.revealed`). Returns those parts; none when the block already showed.
    private func revealOpeningBlock(_ block: SidebarBlockRowView, keeping item: NSView) -> [NSView] {
        guard block.alphaValue < 1 else { return [] }
        Motion.withoutAnimation { block.alphaValue = 1 }
        block.layer?.removeAnimation(forKey: "opacity")
        let region = block.region
        let parts = region.headerViews.values.map { $0 as NSView } + region.itemViews.values.filter { $0 !== item }.map { $0 as NSView }
        return parts.filter { $0.superview != nil && !$0.isHidden && $0.alphaValue > 0 }
    }

    /// An unpin's arriving list row: it is laid out on its slot, opaque and unclipped, and flies there from the item's
    /// frame drawn at the move's begin. Returns its flight.
    func unpinFlight(_ view: SidebarRowView, to target: NSRect, from source: SidebarPinFlightSource) -> SidebarPinFlight {
        Motion.withoutAnimation {
            view.frame = target
            view.alphaValue = 1
            view.clipsToBounds = false
            view.layoutSubtreeIfNeeded()
        }
        raiseForFlight(view)
        // Fill to fill: the row (its bounds are its fill) starts on the item's pill, not on the item's wider bounds
        // (PIN7 films: for the unpin's first frames the row was wider than the column).
        let start: @MainActor (CFTimeInterval) -> NSRect = { [weak self] time in
            let pill = source.frame(at: time).insetBy(dx: source.inset, dy: 0)
            return self?.convert(pill, to: view.superview) ?? pill
        }
        let title = titleOffset(of: view, from: source)
        return SidebarPinFlight(view: view, start: start, title: title,
                                leavingGlyph: leavingGlyph(on: view, from: source, riding: title?.offset ?? .zero))
    }

    /// The item's pin on the arriving row (both flipped, the row starting on the item's pill): where the item drew it at
    /// the start, less `riding`, the title's start offset it rides back on (`SidebarPinFlight.start`).
    private func leavingGlyph(on view: NSView, from source: SidebarPinFlightSource, riding: CGPoint) -> NSView? {
        guard let glyph = source.glyph else { return nil }
        let shift = source.inset - Self.fillInset(of: view)
        let copy = DecorativeImageView(frame: glyph.frame.offsetBy(dx: -shift - riding.x, dy: -riding.y))
        copy.image = glyph.image
        copy.contentTintColor = glyph.tint
        copy.wantsLayer = true
        view.addSubview(copy)
        return copy
    }

    /// How far `view`'s title must start from its own place so it draws on the leaving view's title: `view` starts on
    /// the source's frame, so its pen starts there plus its own pen origin. The containers share the list's scale and
    /// flip, so the offset is the same in the title's superview.
    private func titleOffset(of view: NSView, from source: SidebarPinFlightSource) -> (view: NSView, offset: CGPoint)? {
        guard let sourcePen = source.pen, let titled = view as? any SidebarRenameTitle, let pen = titled.titlePenOrigin?.pointValue,
              let title = Self.flightTitle(of: view) else { return nil }
        // The view starts on the source's frame moved by the fills' inset difference (fill to fill), so the offset is the
        // difference of the pens' places in their views less that move.
        let shift = source.inset - Self.fillInset(of: view)
        let offset = CGPoint(x: sourcePen.x - pen.x - shift, y: sourcePen.y - pen.y)
        guard abs(offset.x) > 0.25 || abs(offset.y) > 0.25 else { return nil }
        return (title, offset)
    }

    /// How far `view`'s fill is inset from its sides: a pinned item's pill; a list row's bounds are its fill.
    static func fillInset(of view: NSView) -> CGFloat { (view as? SidebarItemRowView)?.fillInset ?? 0 }

    /// The label a row or a pinned item draws its title in.
    static func flightTitle(of view: NSView) -> NSView? {
        if let row = view as? WorkspaceRowView { return row.title }
        if let item = view as? SidebarItemRowView { return item.title }
        return nil
    }

    /// Draws `view` above the rows it crosses while it flies (z position, not a re-add: re-adding a view delays its
    /// first frames, cx-ai79). A flying row or item is opaque, on the sidebar's own ground: a title it passes never
    /// shows through it (p1 films 31fec6d8: the titles printed over each other). The move's end puts it back
    /// (`landFlights`). An item keeps its own ground on itself (`flightGround`), saved once: an item still raised by
    /// an earlier flight (a re-pin before that one ended) shows the opaque one now, which is not its own. Returns an
    /// item's flight serial.
    @discardableResult
    private func raiseForFlight(_ view: NSView) -> Int? {
        view.layer?.zPosition = 1
        // A list row paints its own fill on its layer at every display pass: it keeps the ground under that fill.
        if let row = view as? WorkspaceRowView {
            row.flightGround = Palette.sidebarBackground
            return nil
        }
        guard let item = view as? SidebarItemRowView, let layer = view.layer else { return nil }
        item.flightSerial &+= 1
        if item.flightGround == nil { item.flightGround = SidebarFlightGround(color: layer.backgroundColor, cornerRadius: layer.cornerRadius) }
        var ground: CGColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance { ground = Palette.sidebarBackground.withAlphaComponent(1).cgColor }
        Motion.withoutAnimation {
            layer.backgroundColor = ground
            layer.cornerRadius = SidebarStyle.rowCornerRadius
        }
        return item.flightSerial
    }

    /// The flights' views draw at their places in the stack again once the move ended, on no ground of their own. An
    /// item a newer flight raised since (unpinned and pinned again before this move ended) stays up for that flight.
    static func landFlights(_ flights: [SidebarPinFlight]) {
        for flight in flights {
            flight.leavingGlyph?.removeFromSuperview()
            if let item = flight.view as? SidebarItemRowView {
                guard item.flightSerial == flight.serial else { continue }
                flight.glyph?.layer?.mask = nil
                item.landFlight()
            } else {
                flight.view.layer?.zPosition = 0
                (flight.view as? SidebarRowView)?.flightGround = nil
            }
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
