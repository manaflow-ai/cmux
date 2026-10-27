import CmuxNextDesign
import CoreGraphics

/// One structural change of a screen (split, close, zoom, New Column, a released divider) as values:
/// where each changed pane, divider, chrome sublayer and camera rests before and after it, and the
/// spring token each one takes (plans/cmux-next/chrome-parity/p03-rendering.md R2).
///
/// This is Chrome's commit split (cc/trees/layer_tree_host.cc `LayerTreeHost::FinishCommit` with
/// cc/animation/keyframe_model.cc): the main thread computes the rest geometry once, in the key's
/// turn, and the animations that carry the layers there run on the compositor. Here the render
/// server runs them as additive springs (`RenderSpring`), so the plan holds model values only: a
/// change that lands mid-motion is a new plan from the previous rest to the next one, and the
/// springs already running carry the velocity. Nothing here reads `presentation()` or a running
/// spring.
///
/// Rects are in each item's placement space: a strip pane or divider in the strip's content space
/// (the strip container's bounds, before the strip camera), a docked one (or any in a plain split
/// tree) in the screen view's coordinates; a row column's content before its row offset and a
/// scroll area's before its area offset. The camera moves those containers (`camera`), from its
/// `from` values when the change starts. An item that changed container (a zoom takes its pane out
/// of the strip, an undock puts it in) has `from` converted into its new container at those start
/// values, so `from` plus the camera's `from` is where it showed.
///
/// Only what changed is listed: a pane whose rest rect and container are the same in both
/// geometries is absent, even when the camera carries it. A structural change the CPU path snaps
/// (`ScreenContentView.reconcile`: a column inserted or appended where no pane gave up its room)
/// lists what moved with `from == to`: set at its rest, no spring.
nonisolated struct PaneMotionPlan: Hashable, Sendable {
    /// What the change was, which picks the springs (`PaneMotionVariant`).
    nonisolated enum Kind: Hashable, Sendable {
        /// One pane added beside the pane that gave up its room (`PaneArrival`).
        case split
        /// Panes only went away; the ones left grow over the space.
        case close
        /// A pane zooms to fill the screen and covers the others.
        case zoomIn
        /// The zoomed pane goes back to its slot over the others.
        case zoomOut
        /// Anything else: a ratio or width change (sprung), a column added or moved (set at rest
        /// unless it lands while panes still move).
        case move
    }

    /// A zoom in the change: the pane that zooms in or back out.
    nonisolated enum ZoomChange: Hashable, Sendable {
        case zoomIn(PaneID)
        case zoomOut(PaneID)
    }

    /// A value before and after the change.
    nonisolated struct Travel<Value: Hashable & Sendable>: Hashable, Sendable {
        var from: Value
        var to: Value

        /// The item is set at its rest value with no spring.
        var isStill: Bool { from == to }
    }

    nonisolated enum Presence: Hashable, Sendable {
        /// In both layouts: springs from `from` to `to`.
        case stays
        /// New: starts at `from` (a split's sliver on the edge it grows from, or `to` itself when
        /// it lands in place).
        case appears
        /// Gone: `from` is where it rested; it leaves at once (its neighbours cover the space).
        case disappears
    }

    /// Where a pane stacks while the change runs (`ScreenContentView.rank`).
    nonisolated enum ZoomRank: Hashable, Sendable {
        case normal
        /// The zooming pane: above the docks and every other pane until it lands.
        case front
    }

    /// The pane's resting cell size, padding and bands, laid out the way `PaneOverlayView` lays its
    /// sublayers out (in the host's own coordinates, flipped): the sublayers that keep their
    /// thickness while the cell resizes, so each gets its own spring with the host's token.
    nonisolated struct ChromeFrames: Hashable, Sendable {
        /// The padded content rect: the inactive dim.
        var padded: CGRect
        /// The rounded content area between header and footer: border, attention ring, focus
        /// ring, glow clip and focus flash.
        var rounded: CGRect
        /// Corner radius of the border, the attention ring and the dim.
        var cornerRadius: CGFloat
        /// Corner radius of the focus ring, its glow and the flash (`focusRing.cornerRadius`).
        var ringCornerRadius: CGFloat
        /// The tab strip band anchored to the padded rect's top edge (zero height without one).
        var header: CGRect
        /// The band anchored to the padded rect's bottom edge (a tab strip at the bottom).
        var footer: CGRect
        /// The dim rounds its top corners (no header) and its bottom corners (no footer).
        var dimRoundsTop: Bool
        var dimRoundsBottom: Bool

        init(cellSize size: CGSize, shape: ChromeShape, bands: ChromeBands) {
            var style = LayoutStyle()
            style.panePadding = shape.padding
            style.paneCornerRadius = shape.cornerRadius
            let padded = PaneChromeGeometry.contentRect(forCell: CGRect(origin: .zero, size: size), style: style)
            let rounded = PaneChromeGeometry.roundedRect(inPadded: padded, headerHeight: bands.header, footerHeight: bands.footer)
            let radius = PaneChromeGeometry.cornerRadius(for: rounded, style: style)
            let ringLimit = min(rounded.width, rounded.height) / 2
            // The same clamps as `PaneChromeGeometry.roundedRect`: the bands are what it leaves out.
            let top = min(max(0, bands.header), padded.height)
            let bottom = min(max(0, bands.footer), padded.height - top)
            self.padded = padded
            self.rounded = rounded
            cornerRadius = radius
            ringCornerRadius = shape.ringCornerRadius.map { min($0, ringLimit) } ?? radius
            header = CGRect(x: padded.minX, y: padded.minY, width: padded.width, height: top)
            footer = CGRect(x: padded.minX, y: padded.maxY - bottom, width: padded.width, height: bottom)
            dimRoundsTop = bands.header <= 0
            dimRoundsBottom = bands.footer <= 0
        }
    }

    /// The live pane shape (`layout.panePadding`, `layout.paneCornerRadius`, `focusRing.cornerRadius`).
    nonisolated struct ChromeShape: Hashable, Sendable {
        var padding: CGFloat = 0
        var cornerRadius: CGFloat = 0
        var ringCornerRadius: CGFloat?
    }

    /// The header and footer a pane's content reports (`PaneContentChrome`); zero for a whole card.
    nonisolated struct ChromeBands: Hashable, Sendable {
        var header: CGFloat = 0
        var footer: CGFloat = 0
    }

    nonisolated struct PaneChange: Hashable, Sendable {
        var presence: Presence
        var from: CGRect
        var to: CGRect
        /// True when `to` is in the strip's content space, false in the screen view's.
        var inStrip: Bool
        var zoomRank: ZoomRank
        var token: MotionSpring
        /// The chrome sublayers' rest frames at the `from` and `to` sizes; nil when the size does not
        /// change (the sublayers ride the host) or the pane disappears.
        var chrome: Travel<ChromeFrames>?
    }

    /// A divider handle (`DividerHandleView.Kind`, as a value the plan can carry off the main actor).
    nonisolated enum DividerKey: Hashable, Sendable {
        case split(SplitID)
        case columnEdge(ColumnID)
        case rowEdge(ColumnID, RowID)
    }

    nonisolated struct DividerChange: Hashable, Sendable {
        var presence: Presence
        /// The handle's frame (its hit area, as `DividerHandleView` is placed).
        var from: CGRect
        var to: CGRect
        var inStrip: Bool
        var token: MotionSpring
    }

    /// The camera at rest: the strip's scroll offset and each row column's and scroll area's offset.
    /// A missing entry is 0.
    nonisolated struct Camera: Hashable, Sendable {
        var stripOffset: CGFloat = 0
        var rowOffsets: [ColumnID: CGFloat] = [:]
        var areaOffsets: [SplitID: CGFloat] = [:]
    }

    nonisolated struct CameraChange: Hashable, Sendable {
        /// The strip container's x in the view (`ScreenGeometry.stripMinX`: a left dock came or
        /// went). A top dock's `stripMinY` is in the strip panes' own rects, so the container never
        /// moves vertically.
        var stripMinX: Travel<CGFloat>?
        /// The strip's scroll offset. Still (`from == to`) where the change enters or leaves the
        /// strip (a zoom): the camera is set there with no spring.
        var stripOffset: Travel<CGFloat>?
        var rows: [ColumnID: Travel<CGFloat>] = [:]
        var areas: [SplitID: Travel<CGFloat>] = [:]
        /// A close's camera rides the panes' spring (Lawrence 2026-10-20); anything else scrolls.
        var token: MotionSpring = .scroll

        var isEmpty: Bool { stripMinX == nil && stripOffset == nil && rows.isEmpty && areas.isEmpty }
    }

    var kind: Kind
    var panes: [PaneID: PaneChange] = [:]
    var dividers: [DividerKey: DividerChange] = [:]
    var camera = CameraChange()
    /// A zoom in: the panes that left the layout and stay unchanged under the zooming pane until it
    /// lands (`PaneZoomMotion.covered`).
    var covered: Set<PaneID> = []
    /// A zoom out: the panes that come back in place under the pane springing back.
    var uncovered: Set<PaneID> = []

    var isEmpty: Bool { panes.isEmpty && dividers.isEmpty && camera.isEmpty && covered.isEmpty && uncovered.isEmpty }
}

@MainActor
extension PaneMotionPlan {
    /// The plan from `previous` at rest under `fromCamera` to `next` under `toCamera`. Both are base
    /// geometries (`ScreenContentView.baseGeometry`, before row and area offsets), the cameras their
    /// rest offsets. `bands` gives each pane's header and footer (only the panes that resize are
    /// read). `includesRowEdges`: the daemon serves rows-v1, so row edges have handles.
    ///
    /// `structural`: the layout's structure changed (`ScreenLayout.hasSameStructure`); `inFlight`:
    /// panes still moved when it landed. Like the CPU path, a structural change that is not a split,
    /// close or zoom springs only in flight; otherwise its items are set at rest. `handoff`: the pane
    /// that hands what it shows to the pane this split adds (`LayoutModel.pendingContentHandoff`).
    ///
    /// One pass over each geometry's panes and dividers comparing rects; the plan holds only what
    /// changed. On the main actor because the split seed comes from `PaneArrival`, as the CPU path's does.
    static func build(from previous: ScreenGeometry, camera fromCamera: Camera = Camera(),
                      to next: ScreenGeometry, camera toCamera: Camera = Camera(),
                      structural: Bool = true, inFlight: Bool = false,
                      zoom: ZoomChange? = nil, handoff giver: PaneID? = nil, variant: PaneMotionVariant = .standard,
                      shape: ChromeShape = ChromeShape(), bands: [PaneID: ChromeBands] = [:],
                      includesRowEdges: Bool = true) -> PaneMotionPlan {
        let before = Side(geometry: previous, camera: fromCamera), after = Side(geometry: next, camera: toCamera)
        let start = Side.start(from: previous, camera: fromCamera, to: next, camera: toCamera)
        // Only a change that adds one pane and removes none can be a split: `PaneArrival.split`
        // walks every pane, so it runs only then.
        var added: [PaneID] = []
        for pane in next.panes.keys where previous.panes[pane] == nil { added.append(pane) }
        let removesAny = previous.panes.count + added.count != next.panes.count
        var arrivals = added.count == 1 && !removesAny && zoom == nil
            ? PaneArrival.split(previous.panes, from: previous, to: next, offset: fromCamera.stripOffset) : [:]
        // A content handoff: the added pane shows in place and the giver slides in from the screen edge.
        var slide: (giver: PaneID, rect: CGRect)?
        if let giver, let played = PaneArrival.handoff(arrivals, giver: giver, from: previous, to: next, offset: fromCamera.stripOffset) {
            arrivals = played.arrivals
            slide = (giver, played.slide)
        }
        let arrival = arrivals.first?.value
        let kind: Kind = switch zoom {
        case .some(.zoomIn): .zoomIn
        case .some(.zoomOut): .zoomOut
        case .none where arrival != nil: .split
        case .none where added.isEmpty && removesAny && !next.panes.isEmpty: .close
        case .none: .move
        }
        // `ScreenContentView.reconcile`'s `animateFrames`: what it does not carry snaps.
        let springs = !structural || kind != .move || inFlight
        let frameToken: MotionSpring = switch kind {
        case .split: variant.splitSpring
        case .close: variant.closeSpring
        case .zoomIn, .zoomOut, .move: .move
        }
        let zooming: PaneID? = switch zoom {
        case let .some(.zoomIn(pane)), let .some(.zoomOut(pane)): pane
        case .none: nil
        }
        // A split's new dividers start on the edge of a pane beside them; a handoff's are in place.
        let seedsDividers = kind == .split && slide == nil
        var beside: [Beside] = []
        // `PaneArrival` gives strip rects where they show in `next` at the old scroll offset.
        let arrivalShift = next.viewShift(offset: fromCamera.stripOffset)
        var plan = PaneMotionPlan(kind: kind)

        // Panes.
        for (pane, to) in next.panes {
            let into = after.placement(of: pane)
            let rank: ZoomRank = pane == zooming ? .front : .normal
            let token = pane == zooming ? variant.expandSpring : frameToken
            guard let rested = previous.panes[pane] else {
                if kind == .zoomOut {
                    plan.uncovered.insert(pane)
                    continue
                }
                let from = arrivals[pane].map {
                    $0.seed.offsetBy(dx: next.scrolls(pane: pane) ? arrivalShift - start.stripShift : 0, dy: 0)
                } ?? to
                plan.panes[pane] = PaneChange(presence: .appears, from: from, to: to, inStrip: into.inStrip, zoomRank: rank,
                                              token: token, chrome: Self.chrome(from.size, to.size, pane, shape, bands))
                continue
            }
            var from = start.carry(rested, from: before.placement(of: pane), on: before, to: into)
            if let slide, slide.giver == pane {
                from = slide.rect.offsetBy(dx: next.scrolls(pane: pane) ? -start.stripShift : 0, dy: 0)
            }
            if seedsDividers { beside.append(Beside(from: from, to: to, inStrip: into.inStrip)) }
            guard from != to || rank == .front else { continue }
            if !springs { from = to }
            plan.panes[pane] = PaneChange(presence: .stays, from: from, to: to, inStrip: into.inStrip, zoomRank: rank,
                                          token: token, chrome: Self.chrome(from.size, to.size, pane, shape, bands))
        }
        if removesAny {
            for (pane, rested) in previous.panes where next.panes[pane] == nil {
                if kind == .zoomIn {
                    plan.covered.insert(pane)
                    continue
                }
                let out = before.placement(of: pane)
                let from = start.carry(rested, from: out, on: before, to: out)
                plan.panes[pane] = PaneChange(presence: .disappears, from: from, to: from, inStrip: out.inStrip,
                                              zoomRank: .normal, token: frameToken, chrome: nil)
            }
        }

        // Dividers.
        let handlesBefore = before.dividers(includesRowEdges: includesRowEdges)
        var handlesAfter = after.dividers(includesRowEdges: includesRowEdges)
        for (key, handle) in handlesBefore {
            guard let target = handlesAfter.removeValue(forKey: key) else {
                let from = start.carry(handle.rect, from: handle.placement, on: before, to: handle.placement)
                plan.dividers[key] = DividerChange(presence: .disappears, from: from, to: from,
                                                   inStrip: handle.placement.inStrip, token: frameToken)
                continue
            }
            var from = start.carry(handle.rect, from: handle.placement, on: before, to: target.placement)
            guard from != target.rect else { continue }
            if !springs { from = target.rect }
            plan.dividers[key] = DividerChange(presence: .stays, from: from, to: target.rect,
                                               inStrip: target.placement.inStrip, token: frameToken)
        }
        for (key, target) in handlesAfter {
            var from = target.rect
            if seedsDividers, let shift = Self.dividerStart(of: target, beside: beside) ?? arrival?.edgeOffset {
                from = from.offsetBy(dx: shift.dx, dy: shift.dy)
            }
            plan.dividers[key] = DividerChange(presence: .appears, from: from, to: target.rect,
                                               inStrip: target.placement.inStrip, token: frameToken)
        }

        plan.camera = Self.camera(previous, start, after, token: kind == .close ? frameToken : .scroll)
        return plan
    }

    /// A pane in both layouts, where it starts and rests: what a split's new divider rides.
    private struct Beside {
        var from: CGRect
        var to: CGRect
        var inStrip: Bool
    }

    /// Where a split's new divider starts, as a shift from its rest: on the nearest edge of a pane
    /// beside it, where that edge starts (`SplitMotion.startShift`, on rest rects). An even split
    /// (`layout.splitSizing`) may put the divider past the new pane, on the next pane's edge. Nil
    /// when no pane borders it.
    private static func dividerStart(of divider: Handle, beside panes: [Beside]) -> CGVector? {
        let reach: CGFloat = 16, line = divider.rect
        var best: (distance: CGFloat, shift: CGVector)?
        func consider(_ distance: CGFloat, _ shift: CGVector) {
            if distance <= reach, distance < (best?.distance ?? .infinity) { best = (distance, shift) }
        }
        for pane in panes where pane.inStrip == divider.placement.inStrip {
            let from = pane.from, to = pane.to
            if divider.axis == .horizontal {
                guard min(to.maxY, line.maxY) - max(to.minY, line.minY) > 1 else { continue }
                consider(abs(to.maxX - line.midX), CGVector(dx: from.maxX - to.maxX, dy: 0))
                consider(abs(to.minX - line.midX), CGVector(dx: from.minX - to.minX, dy: 0))
            } else {
                guard min(to.maxX, line.maxX) - max(to.minX, line.minX) > 1 else { continue }
                consider(abs(to.maxY - line.midY), CGVector(dx: 0, dy: from.maxY - to.maxY))
                consider(abs(to.minY - line.midY), CGVector(dx: 0, dy: from.minY - to.minY))
            }
        }
        return best?.shift
    }

    /// The chrome sublayers' rest frames at both sizes when the size changes.
    private static func chrome(_ from: CGSize, _ to: CGSize, _ pane: PaneID, _ shape: ChromeShape,
                               _ bands: [PaneID: ChromeBands]) -> Travel<ChromeFrames>? {
        guard from != to else { return nil }
        let paneBands = bands[pane] ?? ChromeBands()
        return Travel(from: ChromeFrames(cellSize: from, shape: shape, bands: paneBands),
                      to: ChromeFrames(cellSize: to, shape: shape, bands: paneBands))
    }

    private static func camera(_ previous: ScreenGeometry, _ start: Side, _ after: Side, token: MotionSpring) -> CameraChange {
        var change = CameraChange(token: token)
        if previous.isColumns != after.geometry.isColumns {
            // Into or out of the strip (a zoom): the strip camera is set at its rest, not sprung.
            change.stripOffset = Travel(from: after.camera.stripOffset, to: after.camera.stripOffset)
        } else if after.geometry.isColumns {
            if start.stripMinX != after.stripMinX { change.stripMinX = Travel(from: start.stripMinX, to: after.stripMinX) }
            if start.camera.stripOffset != after.camera.stripOffset {
                change.stripOffset = Travel(from: start.camera.stripOffset, to: after.camera.stripOffset)
            }
        }
        change.rows = travels(start.camera.rowOffsets, after.camera.rowOffsets)
        change.areas = travels(start.camera.areaOffsets, after.camera.areaOffsets)
        return change
    }

    private static func travels<Key: Hashable>(_ from: [Key: CGFloat], _ to: [Key: CGFloat]) -> [Key: Travel<CGFloat>] {
        var result: [Key: Travel<CGFloat>] = [:]
        for (key, value) in to where (from[key] ?? 0) != value { result[key] = Travel(from: from[key] ?? 0, to: value) }
        for (key, value) in from where to[key] == nil && value != 0 { result[key] = Travel(from: value, to: 0) }
        return result
    }
}
