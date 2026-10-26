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
/// scroll area's before its area offset. The camera moves those containers (`camera`). An item that
/// changed container (a zoom takes its pane out of the strip) has `from` converted through the
/// previous camera, so it starts where it rested.
///
/// Only what changed is listed: a pane whose rest rect and container are the same in both
/// geometries is absent, even when the camera carries it.
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
        /// Anything else: a ratio or width change, a column added or moved.
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
        /// The strip container's origin in the view (`stripMinX`, `stripMinY`: a dock came or went).
        var stripOrigin: Travel<CGPoint>?
        /// The strip's scroll offset. Still (`from == to`) where the change enters or leaves the
        /// strip (a zoom): the camera is set there with no spring.
        var stripOffset: Travel<CGFloat>?
        var rows: [ColumnID: Travel<CGFloat>] = [:]
        var areas: [SplitID: Travel<CGFloat>] = [:]
        /// A close's camera rides the panes' spring (Lawrence 2026-10-20); anything else scrolls.
        var token: MotionSpring = .scroll

        var isEmpty: Bool { stripOrigin == nil && stripOffset == nil && rows.isEmpty && areas.isEmpty }
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
    /// One pass over each geometry's panes and dividers comparing rects; the plan holds only what
    /// changed. On the main actor because the split seed comes from `PaneArrival`, as the CPU path's does.
    static func build(from previous: ScreenGeometry, camera fromCamera: Camera = Camera(),
                      to next: ScreenGeometry, camera toCamera: Camera = Camera(),
                      zoom: ZoomChange? = nil, variant: PaneMotionVariant = .standard,
                      shape: ChromeShape = ChromeShape(), bands: [PaneID: ChromeBands] = [:],
                      includesRowEdges: Bool = true) -> PaneMotionPlan { // perf-hot: 0.2ms motion-frame
        let before = Side(geometry: previous, camera: fromCamera), after = Side(geometry: next, camera: toCamera)
        // Only a change that adds one pane and removes none can be a split: `PaneArrival.split`
        // walks every pane, so it runs only then.
        var added: [PaneID] = []
        for pane in next.panes.keys where previous.panes[pane] == nil { added.append(pane) }
        let removesAny = previous.panes.count + added.count != next.panes.count
        let arrival = added.count == 1 && !removesAny && zoom == nil
            ? PaneArrival.split(previous.panes, from: previous, to: next, offset: fromCamera.stripOffset).first?.value : nil
        let kind: Kind = switch zoom {
        case .some(.zoomIn): .zoomIn
        case .some(.zoomOut): .zoomOut
        case .none where arrival != nil: .split
        case .none where added.isEmpty && removesAny && !next.panes.isEmpty: .close
        case .none: .move
        }
        let frameToken: MotionSpring = switch kind {
        case .split: variant.splitSpring
        case .close: variant.closeSpring
        case .zoomIn, .zoomOut, .move: .move
        }
        let zooming: PaneID? = switch zoom {
        case let .some(.zoomIn(pane)), let .some(.zoomOut(pane)): pane
        case .none: nil
        }
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
                let from = arrival?.seed ?? to
                plan.panes[pane] = PaneChange(presence: .appears, from: from, to: to, inStrip: into.inStrip, zoomRank: rank,
                                              token: token, chrome: Self.chrome(from.size, to.size, pane, shape, bands))
                continue
            }
            let out = before.placement(of: pane)
            let from = out == into ? rested : after.place(before.view(rested, at: out), at: into)
            guard from != to || rank == .front else { continue }
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
                plan.panes[pane] = PaneChange(presence: .disappears, from: rested, to: rested, inStrip: out.inStrip,
                                              zoomRank: .normal, token: frameToken, chrome: nil)
            }
        }

        // Dividers: a split's new divider starts on the edge the new pane grows from.
        let edge = arrival?.edgeOffset ?? .zero
        let handlesBefore = before.dividers(includesRowEdges: includesRowEdges)
        var handlesAfter = after.dividers(includesRowEdges: includesRowEdges)
        for (key, handle) in handlesBefore {
            guard let target = handlesAfter.removeValue(forKey: key) else {
                plan.dividers[key] = DividerChange(presence: .disappears, from: handle.rect, to: handle.rect,
                                                   inStrip: handle.placement.inStrip, token: frameToken)
                continue
            }
            let from = handle.placement == target.placement
                ? handle.rect : after.place(before.view(handle.rect, at: handle.placement), at: target.placement)
            guard from != target.rect else { continue }
            plan.dividers[key] = DividerChange(presence: .stays, from: from, to: target.rect,
                                               inStrip: target.placement.inStrip, token: frameToken)
        }
        for (key, target) in handlesAfter {
            let from = kind == .split ? target.rect.offsetBy(dx: edge.dx, dy: edge.dy) : target.rect
            plan.dividers[key] = DividerChange(presence: .appears, from: from, to: target.rect,
                                               inStrip: target.placement.inStrip, token: frameToken)
        }

        plan.camera = Self.camera(before, after, token: kind == .close ? frameToken : .scroll)
        return plan
    }

    /// The chrome sublayers' rest frames at both sizes when the size changes.
    private static func chrome(_ from: CGSize, _ to: CGSize, _ pane: PaneID, _ shape: ChromeShape,
                               _ bands: [PaneID: ChromeBands]) -> Travel<ChromeFrames>? {
        guard from != to else { return nil }
        let paneBands = bands[pane] ?? ChromeBands()
        return Travel(from: ChromeFrames(cellSize: from, shape: shape, bands: paneBands),
                      to: ChromeFrames(cellSize: to, shape: shape, bands: paneBands))
    }

    private static func camera(_ before: Side, _ after: Side, token: MotionSpring) -> CameraChange {
        var change = CameraChange(token: token)
        let old = before.geometry, new = after.geometry
        if old.isColumns, new.isColumns {
            let from = CGPoint(x: old.stripMinX, y: old.stripMinY), to = CGPoint(x: new.stripMinX, y: new.stripMinY)
            if from != to { change.stripOrigin = Travel(from: from, to: to) }
            if before.camera.stripOffset != after.camera.stripOffset {
                change.stripOffset = Travel(from: before.camera.stripOffset, to: after.camera.stripOffset)
            }
        } else if old.isColumns != new.isColumns {
            // Into or out of the strip (a zoom): the strip camera is set at its rest, not sprung.
            change.stripOffset = Travel(from: after.camera.stripOffset, to: after.camera.stripOffset)
        }
        change.rows = travels(before.camera.rowOffsets, after.camera.rowOffsets)
        change.areas = travels(before.camera.areaOffsets, after.camera.areaOffsets)
        return change
    }

    private static func travels<Key: Hashable>(_ from: [Key: CGFloat], _ to: [Key: CGFloat]) -> [Key: Travel<CGFloat>] {
        var result: [Key: Travel<CGFloat>] = [:]
        for (key, value) in to where (from[key] ?? 0) != value { result[key] = Travel(from: from[key] ?? 0, to: value) }
        for (key, value) in from where to[key] == nil && value != 0 { result[key] = Travel(from: value, to: 0) }
        return result
    }
}

nonisolated extension PaneMotionPlan {
    /// The container an item rests in: the strip or the view, and the row column and scroll area
    /// whose offsets move it.
    nonisolated struct Placement: Hashable, Sendable {
        var inStrip: Bool
        var rowColumn: ColumnID?
        var area: SplitID?
    }

    /// One geometry at its rest camera.
    nonisolated struct Side {
        let geometry: ScreenGeometry
        let camera: Camera

        func placement(of pane: PaneID) -> Placement {
            Placement(inStrip: geometry.isColumns && !geometry.fixedPanes.contains(pane),
                      rowColumn: geometry.rowColumnOfPane[pane], area: geometry.scrollAreaOfPane[pane])
        }

        /// `rect` (in `placement`'s space) in the view's coordinates at this camera.
        func view(_ rect: CGRect, at placement: Placement) -> CGRect {
            let delta = shift(placement)
            return rect.offsetBy(dx: delta.dx, dy: delta.dy)
        }

        /// A view rect in `placement`'s space at this camera.
        func place(_ rect: CGRect, at placement: Placement) -> CGRect {
            let delta = shift(placement)
            return rect.offsetBy(dx: -delta.dx, dy: -delta.dy)
        }

        private func shift(_ placement: Placement) -> CGVector {
            let strip = placement.inStrip ? geometry.viewShift(offset: camera.stripOffset) : 0
            let area = placement.area.map { camera.areaOffsets[$0] ?? 0 } ?? 0
            let row = placement.rowColumn.map { camera.rowOffsets[$0] ?? 0 } ?? 0
            return CGVector(dx: strip - area, dy: -row)
        }

        /// Every divider handle's frame and container, as `ScreenContentView.reconcile` places them.
        func dividers(includesRowEdges: Bool) -> [DividerKey: (rect: CGRect, placement: Placement)] {
            var result: [DividerKey: (rect: CGRect, placement: Placement)] = [:]
            result.reserveCapacity(geometry.dividers.count + geometry.columnEdges.count + (includesRowEdges ? geometry.rowEdges.count : 0))
            for divider in geometry.dividers {
                let placement = Placement(inStrip: geometry.isColumns && !geometry.fixedSplits.contains(divider.id),
                                          rowColumn: geometry.rowColumnOfSplit[divider.id], area: geometry.scrollAreaOfSplit[divider.id])
                result[.split(divider.id)] = (divider.hitFrame, placement)
            }
            for edge in geometry.columnEdges {
                result[.columnEdge(edge.column)] = (edge.hitFrame, Placement(inStrip: inStrip(column: edge.column)))
            }
            if includesRowEdges {
                for edge in geometry.rowEdges {
                    result[.rowEdge(edge.column, edge.upper)] = (edge.hitFrame, Placement(inStrip: inStrip(column: edge.column),
                                                                                          rowColumn: edge.column))
                }
            }
            return result
        }

        private func inStrip(column: ColumnID) -> Bool {
            geometry.isColumns && !geometry.dock.contains { $0.column == column }
        }
    }
}
