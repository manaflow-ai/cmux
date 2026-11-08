import AppKit
import CmuxNextDesign
import QuartzCore
import os

nonisolated let pinDiag = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar.pindiag")

/// diag (not for merge): logs every animation add/remove on a pinned item's layer, with the caller's stack, for 150 ms
/// after its flight starts (`armedAt`).
/// Logs when a flying item's move ends and whether it ran to its end (diagnostic build only, not for merge).
nonisolated final class PinDiagStop: NSObject, CAAnimationDelegate {
    let key: String
    let armedAt: Double
    init(key: String, armedAt: Double) {
        self.key = key
        self.armedAt = armedAt
    }
    func animationDidStart(_ anim: CAAnimation) {
        pinDiag.notice("didStart key=\(self.key, privacy: .public) t+\(CACurrentMediaTime() - self.armedAt)")
    }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        pinDiag.notice("didStop key=\(self.key, privacy: .public) finished=\(flag) t+\(CACurrentMediaTime() - self.armedAt)")
    }
}

nonisolated final class PinDiagLayer: CALayer {
    /// When the flight armed the log (a layer KVC value, so the layer keeps no extra stored state).
    static let armedKey = "pinDiagArmedAt"

    private func trace(_ op: String, _ key: String?) {
        guard key != Self.armedKey, let armedAt = value(forKey: Self.armedKey) as? Double else { return }
        let dt = CACurrentMediaTime() - armedAt
        guard dt < 0.15 else { return }
        let keys = (animationKeys() ?? []).joined(separator: "+")
        let line = "\(op) key=\(key ?? "nil") t+\(String(format: "%.4f", dt)) main=\(Thread.isMainThread) keys=\(keys)"
        pinDiag.notice("layerop \(line, privacy: .public)")
    }

    override func add(_ anim: CAAnimation, forKey key: String?) {
        trace("add", key)
        guard let armedAt = value(forKey: Self.armedKey) as? Double, CACurrentMediaTime() - armedAt < 0.15,
              let key, key.hasPrefix("move."), let copy = anim.copy() as? CAAnimation else {
            return super.add(anim, forKey: key)
        }
        var chain: [String] = []
        var node: CALayer? = self
        while let n = node, chain.count < 12 {
            chain.append("\(type(of: n))(sp\(n.speed) to\(n.timeOffset) bt\(n.beginTime))")
            node = n.superlayer
        }
        let local = convertTime(CACurrentMediaTime(), from: nil)
        let spring = anim as? CASpringAnimation
        pinDiag.notice("""
        timing key=\(key, privacy: .public) begin=\(anim.beginTime) localNow=\(local) media=\(CACurrentMediaTime()) \
        dur=\(anim.duration) settle=\(spring?.settlingDuration ?? -1) stiff=\(spring?.stiffness ?? -1) damp=\(spring?.damping ?? -1) \
        speed=\(anim.speed) fill=\(anim.fillMode.rawValue, privacy: .public) removed=\(anim.isRemovedOnCompletion) \
        from=\(String(describing: (anim as? CABasicAnimation)?.fromValue), privacy: .public) \
        txDisable=\(CATransaction.disableActions()) txDur=\(CATransaction.animationDuration()) \
        chain=\(chain.joined(separator: " < "), privacy: .public)
        """)
        copy.delegate = PinDiagStop(key: key, armedAt: armedAt)
        super.add(copy, forKey: key)
    }

    override func removeAnimation(forKey key: String) {
        trace("remove", key)
        super.removeAnimation(forKey: key)
    }

    override func removeAllAnimations() {
        trace("removeAll", nil)
        super.removeAllAnimations()
    }

    override func removeFromSuperlayer() {
        trace("removeFromSuperlayer", nil)
        super.removeFromSuperlayer()
    }
}

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
    /// The view's own ground before the flight gave it an opaque one (`raiseForFlight`), put back when it lands.
    var ground: SidebarFlightGround?
    /// The parts of a block that opens with this pin other than the flying item (its section header): the block itself
    /// shows at once so the item never fades, and these fade in on the move instead.
    var revealed: [NSView] = []

    /// Starts the flight at `now`, the move's one begin time: the view starts where the leaving view is drawn then.
    func start(_ token: MotionSpring, now: CFTimeInterval) {
        let diagFrom = NSStringFromRect(start(now)), diagTo = NSStringFromRect(view.frame), diagType = String(describing: type(of: view))
        pinDiag.notice("flight start view=\(diagType, privacy: .public) from=\(diagFrom, privacy: .public) to=\(diagTo, privacy: .public)")
        (view.layer as? PinDiagLayer)?.setValue(CACurrentMediaTime(), forKey: PinDiagLayer.armedKey)
        SidebarDragSpring.fly(view, from: start(now), token, now: now)
        let diagKeys = (view.layer?.animationKeys() ?? []).joined(separator: ",")
        pinDiag.notice("flight keys=\(diagKeys, privacy: .public)")
        let diagLayer = view.layer.map(ObjectIdentifier.init)
        for delay in [0.0, 0.008, 0.03, 0.08] {
            // concurrency-allow: diagnostic build only (not for merge): reads the flying layer later on the main queue
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view, let layer = view.layer else { return }
                var chain: [String] = []
                var node: NSView? = view
                while let n = node {
                    chain.append("\(type(of: n))(z\(n.layer?.zPosition ?? -1) clip\(n.clipsToBounds) m\(n.layer?.masksToBounds ?? false) a\(n.alphaValue) h\(n.isHidden) keys\((n.layer?.animationKeys() ?? []).joined(separator: "+")))")
                    node = n.superview
                    if chain.count > 4 { break }
                }
                let same = diagLayer == ObjectIdentifier(layer)
                let shown = layer.presentation().map { NSStringFromPoint($0.position) } ?? "nil"
                let model = NSStringFromPoint(layer.position)
                let line = "t+\(delay) sameLayer=\(same) model=\(model) shown=\(shown) chain=\(chain.joined(separator: " < "))"
                pinDiag.notice("flight later \(line, privacy: .public)")
            }
        }
        if let title { SidebarDragSpring.offset(title.view, by: title.offset, token, now: now) }
        if let glyph { SidebarDragSpring.attach(glyph) }
        if let layer = glyph?.layer { SidebarDragSpring.appear(layer, token, now: now) }
        revealed.forEach(SidebarDragSpring.attach)
        for layer in revealed.compactMap(\.layer) { SidebarDragSpring.appear(layer, token, now: now) }
    }

    /// The begin of a move with flights: the first frame that can show it, one refresh of `view`'s screen from now
    /// (a frame already due shows no change made after its commit). Before it the springs hold their start
    /// (`fillMode` backwards), so the first frame that shows the change shows the workspace where it was, at rest.
    static func begin(in view: NSView, now: CFTimeInterval = CACurrentMediaTime()) -> CFTimeInterval {
        let refresh = view.window?.screen?.minimumRefreshInterval ?? 1.0 / 60
        return now + (refresh > 0 ? refresh : 1.0 / 60)
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
        let diagPinned = blockWorkspaces(blocks).map(\.rawValue).sorted().joined(separator: ",")
        let diagLeaving = rowViews.keys.filter { layout.row(for: $0) == nil }.map { "\($0)" }.joined(separator: ",")
        let diagClosing = subviews.compactMap { $0 as? SidebarRowView }.filter { $0.closingEnd != nil }.map { "\($0.key)" }.joined(separator: ",")
        let diagState = "moves=\(moves) drag=\(drag != nil) settling=\(settling != nil) landing=\(landing != nil) infos=\(blocks?.infos.count ?? -1)"
        pinDiag.notice("sources \(diagState, privacy: .public) pinned=[\(diagPinned, privacy: .public)] leaving=[\(diagLeaving, privacy: .public)] closing=[\(diagClosing, privacy: .public)]")
        guard moves, drag == nil, settling == nil, landing == nil else { return sources }
        let pinned = blockWorkspaces(blocks)
        for (key, view) in rowViews {
            guard case let .workspace(id) = key, layout.row(for: key) == nil, pinned.contains(id), !view.isHidden else { continue }
            sources.pins[id] = source(of: view)
        }
        // A pin's row an earlier update already closes (the rows reached the list before the blocks: an app that sends
        // them in two updates): the block's item flies from where the closing row is drawn, and the row goes in the
        // same transaction. Nothing waits for the second update.
        for view in subviews.lazy.compactMap({ $0 as? SidebarRowView }) where view.closingEnd != nil && !view.isHidden {
            guard case let .workspace(id) = view.key, rowViews[view.key] == nil, pinned.contains(id), sources.pins[id] == nil
            else { continue }
            sources.pins[id] = source(of: view)
            sources.closing.append(view)
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

    /// `view`'s drawn frame in the list over time, with its title's pen origin.
    private func source(of view: NSView) -> SidebarPinFlightSource {
        var source = drawnPath(of: view)
        source.pen = (view as? any SidebarRenameTitle)?.titlePenOrigin?.pointValue
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
                  let item = block.region.itemView(workspace: id), let container = item.superview else {
                let diagBlocks = rowViews.values.compactMap { $0 as? SidebarBlockRowView }.map { block in
                    block.region.itemViews.values.map { "\($0.info.workspace?.rawValue ?? "nil")/\($0.superview != nil)" }.joined(separator: ",")
                }.joined(separator: "|")
                pinDiag.notice("pinFlights no item for \(id.rawValue, privacy: .public) blocks=\(diagBlocks, privacy: .public)")
                continue
            }
            let diagItem = NSStringFromRect(item.frame), diagSource = NSStringFromRect(source.frame(at: CACurrentMediaTime()))
            pinDiag.notice("pinFlights item for \(id.rawValue, privacy: .public) frame=\(diagItem, privacy: .public) src=\(diagSource, privacy: .public)")
            // The block moves on the same spring from where it is drawn at the begin (its move is added first): the
            // item's start is the source less that, both at the begin.
            let start: @MainActor (CFTimeInterval) -> NSRect = { [weak self] time in
                guard let self else { return source.frame(at: time) }
                let blockShown = drawnFrame(of: block, now: time)
                let inBlock = source.frame(at: time).offsetBy(dx: -blockShown.minX, dy: -blockShown.minY)
                return container.convert(inBlock, from: block)
            }
            block.clipsToBounds = false
            raiseForFlight(block)
            let ground = raiseForFlight(item)
            flights.append(SidebarPinFlight(view: item, start: start, title: titleOffset(of: item, from: source), glyph: item.pinGlyph,
                                            ground: ground, revealed: revealOpeningBlock(block, keeping: item)))
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
        let ground = raiseForFlight(view)
        let start: @MainActor (CFTimeInterval) -> NSRect = { [weak self] time in
            self?.convert(source.frame(at: time), to: view.superview) ?? source.frame(at: time)
        }
        return SidebarPinFlight(view: view, start: start, title: titleOffset(of: view, from: source), ground: ground)
    }

    /// How far `view`'s title must start from its own place so it draws on the leaving view's title: `view` starts on
    /// the source's frame, so its pen starts there plus its own pen origin. The containers share the list's scale and
    /// flip, so the offset is the same in the title's superview.
    private func titleOffset(of view: NSView, from source: SidebarPinFlightSource) -> (view: NSView, offset: CGPoint)? {
        guard let sourcePen = source.pen, let titled = view as? any SidebarRenameTitle, let pen = titled.titlePenOrigin?.pointValue,
              let title = Self.flightTitle(of: view) else { return nil }
        // Both pens sit on the same start frame, so the offset is the difference of their places in their views.
        let offset = CGPoint(x: sourcePen.x - pen.x, y: sourcePen.y - pen.y)
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
    /// first frames, cx-ai79). A flying row or item is opaque, on the sidebar's own ground: a title it passes never
    /// shows through it (p1 films 31fec6d8: the titles printed over each other). The move's end puts it back
    /// (`landFlights`).
    @discardableResult
    private func raiseForFlight(_ view: NSView) -> SidebarFlightGround? {
        view.layer?.zPosition = 1
        // A list row paints its own fill on its layer at every display pass: it keeps the ground under that fill.
        if let row = view as? WorkspaceRowView {
            row.flightGround = Palette.sidebarBackground
            return nil
        }
        guard view is SidebarItemRowView, let layer = view.layer else { return nil }
        let before = SidebarFlightGround(color: layer.backgroundColor, cornerRadius: layer.cornerRadius)
        var ground: CGColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance { ground = Palette.sidebarBackground.withAlphaComponent(1).cgColor }
        Motion.withoutAnimation {
            layer.backgroundColor = ground
            layer.cornerRadius = SidebarStyle.rowCornerRadius
        }
        return before
    }

    /// The flights' views draw at their places in the stack again once the move ended, on no ground of their own.
    static func landFlights(_ flights: [SidebarPinFlight]) {
        for flight in flights {
            flight.view.layer?.zPosition = 0
            (flight.view as? SidebarRowView)?.flightGround = nil
            if let block = flight.view.enclosingRow { block.layer?.zPosition = 0 }
            if let ground = flight.ground {
                Motion.withoutAnimation {
                    flight.view.layer?.backgroundColor = ground.color
                    flight.view.layer?.cornerRadius = ground.cornerRadius
                }
            }
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
