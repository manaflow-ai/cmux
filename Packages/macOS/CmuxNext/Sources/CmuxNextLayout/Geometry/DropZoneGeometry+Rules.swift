import CCmuxLayoutReducerFFI
import CoreGraphics
import Foundation

// The rules of ``DropZoneGeometry`` are Rust's: cmux-layout-reducer `pane_drop_zones` behind the app FFI's
// `cmux_pane_drop_*` (cmux-layout-reducer-ffi `pane_drop_zones.rs`). This reference owns one screen handle, made
// from one screen's geometry, its panes' tab bars and the style, and turns ``DropTarget``s into the C target (a pane
// or gap index, a zone or edge code) and back. Nothing here decides.
//
// Cost: `init` encodes the screen to JSON once; each question after crosses numbers only (no JSON, no allocation).
// `ScreenContentView` keeps one per layout, viewport, tab bars and style (`DropAnswerMemo.zoneRules`), so a pointer
// move over the same layout makes none.
nonisolated final class DropZoneRules {
    let screen: ScreenID
    let geometry: ScreenGeometry
    let headers: [PaneID: CGFloat]
    let footers: [PaneID: CGFloat]
    let style: LayoutStyle
    private let pointer: OpaquePointer?
    /// The handle's panes, in the tie-break order (ascending).
    private let panes: [PaneID]
    private let paneIndex: [PaneID: UInt32]
    /// The handle's gaps, in hit order (`ScreenGeometry.gapZones`).
    private let gaps: [ColumnID?]

    init(screen: ScreenID, geometry: ScreenGeometry, headers: [PaneID: CGFloat] = [:], footers: [PaneID: CGFloat] = [:],
         style: LayoutStyle) {
        self.screen = screen
        self.geometry = geometry
        self.headers = headers
        self.footers = footers
        self.style = style
        let panes = geometry.panes.keys.sorted()
        self.panes = panes
        var index: [PaneID: UInt32] = [:]
        for (offset, pane) in panes.enumerated() { index[pane] = UInt32(offset) }
        paneIndex = index
        gaps = geometry.gapZones.map(\.after)
        let request = Request(
            width: Double(geometry.viewport.width), height: Double(geometry.viewport.height),
            panes: panes.map { pane in
                Request.Pane(rect: Request.Rect(geometry.panes[pane] ?? .zero), fixed: geometry.fixedPanes.contains(pane),
                             header: Double(headers[pane] ?? 0), footer: Double(footers[pane] ?? 0))
            },
            gaps: geometry.gapZones.map { Request.Rect($0.frame) },
            docks: geometry.dock.map { Request.Dock(edge: $0.dock.edge.rawValue, frame: Request.Rect($0.frame), cover: Request.Rect($0.cover)) },
            uncovered: Request.Rect(CGRect(x: geometry.uncoveredMinX, y: geometry.uncoveredMinY,
                                           width: geometry.uncoveredMaxX - geometry.uncoveredMinX,
                                           height: geometry.uncoveredMaxY - geometry.uncoveredMinY)),
            stripMinX: Double(geometry.stripMinX), style: Request.Style(style))
        // A non-finite number does not encode: the handle is null and every question answers nothing.
        let json = (try? JSONEncoder().encode(request)) ?? Data()
        pointer = json.withUnsafeBytes { bytes in
            cmux_pane_drop_screen_new(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
    }

    /// Only the style: for ``zone(at:in:header:footer:previous:)``.
    convenience init(style: LayoutStyle) {
        self.init(screen: ScreenID(rawValue: ""), geometry: ScreenGeometry(viewport: .zero, contentWidth: 0, isColumns: false), style: style)
    }

    deinit {
        cmux_pane_drop_screen_free(pointer)
    }

    /// Whether this handle answers for these inputs.
    func matches(screen: ScreenID, geometry: ScreenGeometry, headers: [PaneID: CGFloat], footers: [PaneID: CGFloat],
                 style: LayoutStyle) -> Bool {
        self.screen == screen && self.style == style && self.headers == headers && self.footers == footers && self.geometry == geometry
    }

    /// ``DropZoneGeometry/zone(at:in:header:footer:style:previous:)``.
    func zone(at point: CGPoint, in rect: CGRect, header: CGFloat, footer: CGFloat, previous: PaneDropZone?) -> PaneDropZone {
        var out = UInt8.max
        let code = cmux_pane_drop_zone(pointer, Double(point.x), Double(point.y), Self.c(rect), Double(header), Double(footer),
                                       previous.map(Self.code) ?? .max, &out)
        return code == 1 ? Self.zone(out) ?? .center : .center
    }

    /// ``DropZoneGeometry/target(atView:offset:screen:geometry:headers:footers:style:previous:)``.
    func target(atView point: CGPoint, offset: CGFloat, previous: DropTarget?) -> DropTarget? {
        answer(previous) { previous, out in
            cmux_pane_drop_target(pointer, Double(point.x), Double(point.y), Double(offset), previous, out)
        }
    }

    /// ``DropZoneGeometry/target(at:screen:geometry:headers:footers:style:previous:)`` (content space).
    func target(at point: CGPoint, previous: DropTarget?) -> DropTarget? {
        answer(previous) { previous, out in
            cmux_pane_drop_target_in_content(pointer, Double(point.x), Double(point.y), previous, out)
        }
    }

    /// ``DropZoneGeometry/dockTarget(atView:screen:geometry:style:topInset:bottomInset:previous:)``.
    func dockTarget(atView point: CGPoint, topInset: CGFloat, bottomInset: CGFloat, previous: DropTarget?) -> DropTarget? {
        answer(previous) { previous, out in
            cmux_pane_drop_dock(pointer, Double(point.x), Double(point.y), Double(topInset), Double(bottomInset), previous, out)
        }
    }

    /// What `target`'s preview fills in view coordinates with the strip at `offset`: the highlight
    /// (``DropZoneGeometry/highlightRectInView(for:offset:geometry:style:)``), the region
    /// (``DropZoneGeometry/regionRectInView(for:offset:geometry:style:)``) and a pane's body below its tab bar.
    /// At `offset` `geometry.stripMinX` view and content coordinates are the same.
    func rects(for target: DropTarget, offset: CGFloat) -> (highlight: CGRect, region: CGRect, body: CGRect?)? {
        var target = c(target, sameScreen: false) ?? CmuxPaneDropTarget()
        var out = CmuxPaneDropRects()
        guard cmux_pane_drop_rects(pointer, &target, Double(offset), &out) == 1 else { return nil }
        return (Self.rect(out.highlight), Self.rect(out.region), out.has_body == 1 ? Self.rect(out.body) : nil)
    }

    /// ``DropZoneGeometry/classicPaneHighlight(body:zone:padding:)``.
    static func classicPaneHighlight(body: CGRect, zone: PaneDropZone, padding: CGFloat) -> CGRect {
        var out = CmuxPaneDropRect()
        guard cmux_pane_drop_classic_highlight(c(body), code(zone), Double(padding), &out) == 1 else { return .null }
        return rect(out)
    }

    private func answer(_ previous: DropTarget?,
                        _ ask: (UnsafePointer<CmuxPaneDropTarget>?, UnsafeMutablePointer<CmuxPaneDropTarget>) -> Int32) -> DropTarget? {
        var out = CmuxPaneDropTarget()
        let code: Int32 = if let shown = previous.flatMap({ c($0, sameScreen: true) }) {
            withUnsafePointer(to: shown) { ask($0, &out) }
        } else {
            ask(nil, &out)
        }
        return code == 1 ? target(out) : nil
    }

    /// The C target of `target`. A pane of another screen keeps its zone with an index past the panes (a gap still
    /// shrinks for it); a column not on this handle gets an index past the gaps. With `sameScreen` (a previous
    /// target), another screen's column or dock is no target of this one, as ``DropTarget``'s equality says.
    private func c(_ target: DropTarget, sameScreen: Bool) -> CmuxPaneDropTarget? {
        var out = CmuxPaneDropTarget()
        switch target {
        case let .pane(pane, zone):
            out.kind = 1 // CMUX_PANE_DROP_KIND_PANE
            out.index = paneIndex[pane] ?? .max
            out.zone = Self.code(zone)
        case let .newColumn(screen, after):
            out.kind = 2 // CMUX_PANE_DROP_KIND_COLUMN
            let here = !sameScreen || screen == self.screen
            out.index = here ? gaps.firstIndex(of: after).map { UInt32($0) } ?? .max : .max
        case let .newDock(screen, edge):
            if sameScreen, screen != self.screen { return nil }
            out.kind = 3 // CMUX_PANE_DROP_KIND_DOCK
            out.zone = Self.code(edge)
        }
        return out
    }

    private func target(_ c: CmuxPaneDropTarget) -> DropTarget? {
        let index = Int(c.index)
        // CMUX_PANE_DROP_KIND_*: a pane, a new column, a new dock.
        switch c.kind {
        case 1:
            guard index < panes.count, let zone = Self.zone(c.zone) else { return nil }
            return .pane(panes[index], zone)
        case 2:
            guard index < gaps.count else { return nil }
            return .newColumn(screen: screen, after: gaps[index])
        case 3:
            return Self.edge(c.zone).map { .newDock(screen: screen, edge: $0) }
        default:
            return nil
        }
    }

    // CMUX_PANE_DROP_ZONE_* and CMUX_TAB_DROP_EDGE_*: left 0, right 1, top 2, bottom 3, center 4.
    private static func code(_ zone: PaneDropZone) -> UInt8 {
        switch zone {
        case .left: 0
        case .right: 1
        case .top: 2
        case .bottom: 3
        case .center: 4
        }
    }

    private static func zone(_ code: UInt8) -> PaneDropZone? {
        switch code {
        case 0: .left
        case 1: .right
        case 2: .top
        case 3: .bottom
        case 4: .center
        default: nil
        }
    }

    private static func code(_ edge: DockEdge) -> UInt8 {
        switch edge {
        case .left: 0
        case .right: 1
        case .top: 2
        case .bottom: 3
        }
    }

    private static func edge(_ code: UInt8) -> DockEdge? {
        switch code {
        case 0: .left
        case 1: .right
        case 2: .top
        case 3: .bottom
        default: nil
        }
    }

    private static func c(_ rect: CGRect) -> CmuxPaneDropRect {
        CmuxPaneDropRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    private static func rect(_ rect: CmuxPaneDropRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    /// `pane_drop_zones::Screen` as JSON.
    private struct Request: Encodable {
        struct Rect: Encodable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double

            init(_ rect: CGRect) {
                x = Double(rect.minX)
                y = Double(rect.minY)
                width = Double(rect.width)
                height = Double(rect.height)
            }
        }

        struct Pane: Encodable {
            var rect: Rect
            var fixed: Bool
            var header: Double
            var footer: Double
        }

        struct Dock: Encodable {
            var edge: String
            var frame: Rect
            var cover: Rect
        }

        struct Style: Encodable {
            var edgeFraction: Double
            var edgeMinimum: Double
            /// Omitted for no cap (`CGFloat.greatestFiniteMagnitude`): Rust's default is `f64::MAX`.
            var edgeMaximum: Double?
            var hysteresis: Double
            var dockBand: Double
            var dockTopBand: Double
            var panePadding: Double
            var stripGap: Double

            init(_ style: LayoutStyle) {
                edgeFraction = Double(style.dropEdgeFraction)
                edgeMinimum = Double(style.dropEdgeRange.lowerBound)
                let upper = style.dropEdgeRange.upperBound
                edgeMaximum = upper.isFinite && upper < .greatestFiniteMagnitude ? Double(upper) : nil
                hysteresis = Double(style.dropZoneHysteresis)
                dockBand = Double(style.dockDropBand)
                dockTopBand = Double(style.dockTopDropBand)
                panePadding = Double(style.panePadding)
                stripGap = Double(style.stripGap)
            }
        }

        var width: Double
        var height: Double
        var panes: [Pane]
        var gaps: [Rect]
        var docks: [Dock]
        var uncovered: Rect
        var stripMinX: Double
        var style: Style
    }
}
