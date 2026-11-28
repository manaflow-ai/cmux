import CCmuxLayoutReducerFFI
import CoreGraphics
import Foundation

/// One screen's drop geometry held by cmux-layout-reducer (`pane_drop_zones`, the `cmux_pane_drop_*` app FFI): built
/// once from the placed geometry as JSON, then asked per pointer move with numbers only. Nothing here decides: it maps
/// the app's ids and rects into the screen's indices and the answers back. The rules and their tests are in the crate
/// (`src/pane_drop_zones.rs`, `ffi/tests/pane_drop_zones.rs`).
nonisolated final class DropScreen {
    private let handle: OpaquePointer
    /// The panes in tie-break order (by id): the screen's pane indices.
    private let panes: [PaneID]
    /// The column gaps' `after`, in the screen's gap indices.
    private let gaps: [ColumnID?]

    private struct Key: Equatable {
        var geometry: ScreenGeometry?
        var headers: [PaneID: CGFloat]
        var footers: [PaneID: CGFloat]
        var style: LayoutStyle
    }

    /// The screen for these inputs, built fresh (no shared state): nil when the numbers do not encode (a NaN frame).
    static func shared(geometry: ScreenGeometry?, headers: [PaneID: CGFloat], footers: [PaneID: CGFloat],
                       style: LayoutStyle) -> DropScreen? {
        DropScreen(Key(geometry: geometry, headers: headers, footers: footers, style: style))
    }

    private init?(_ key: Key) {
        let geometry = key.geometry
        let panes = (geometry?.panes.keys.sorted() ?? [])
        let request = Request(
            width: Double(geometry?.viewport.width ?? 0), height: Double(geometry?.viewport.height ?? 0),
            panes: panes.compactMap { id in
                guard let geometry, let cell = geometry.panes[id] else { return nil }
                return Request.Pane(rect: Request.Rect(cell), fixed: !geometry.scrolls(pane: id),
                                    header: Double(key.headers[id] ?? 0), footer: Double(key.footers[id] ?? 0))
            },
            gaps: geometry?.gapZones.map { Request.Rect($0.frame) } ?? [],
            docks: geometry?.dock.map { Request.Dock(edge: $0.dock.edge.rawValue, frame: Request.Rect($0.frame), cover: Request.Rect($0.cover)) } ?? [],
            uncovered: Request.Rect(x: Double(geometry?.uncoveredMinX ?? 0), y: Double(geometry?.uncoveredMinY ?? 0),
                                    width: Double((geometry?.uncoveredMaxX ?? 0) - (geometry?.uncoveredMinX ?? 0)),
                                    height: Double((geometry?.uncoveredMaxY ?? 0) - (geometry?.uncoveredMinY ?? 0))),
            stripMinX: Double(geometry?.stripMinX ?? 0),
            style: Request.Style(
                edgeFraction: Double(key.style.dropEdgeFraction), edgeMinimum: Double(key.style.dropEdgeRange.lowerBound),
                edgeMaximum: Double(min(key.style.dropEdgeRange.upperBound, .greatestFiniteMagnitude)), hysteresis: Double(key.style.dropZoneHysteresis),
                dockBand: Double(key.style.dockDropBand), dockTopBand: Double(key.style.dockTopDropBand),
                panePadding: Double(key.style.panePadding), stripGap: Double(key.style.stripGap)))
        guard let json = try? JSONEncoder().encode(request),
              let handle = json.withUnsafeBytes({ cmux_pane_drop_screen_new($0.bindMemory(to: UInt8.self).baseAddress, json.count) })
        else { return nil }
        self.handle = handle
        self.panes = panes
        self.gaps = geometry?.gapZones.map(\.after) ?? []
    }

    deinit { cmux_pane_drop_screen_free(handle) }

    // MARK: Targets

    // The zone and edge codes are CMUX_PANE_DROP_ZONE_* and CMUX_TAB_DROP_EDGE_*: left, right, top, bottom (, center).
    private static let zones: [PaneDropZone] = [.left, .right, .top, .bottom, .center]
    private static let edges: [DockEdge] = [.left, .right, .top, .bottom]

    /// `target` as the screen names it. A previous target of another screen is sent as none, or for a pane, past the panes.
    private func wire(_ target: DropTarget?, screen: ScreenID) -> CmuxPaneDropTarget? {
        switch target {
        case let .pane(pane, zone)?:
            let index = panes.firstIndex(of: pane) ?? panes.count
            return CmuxPaneDropTarget(index: UInt32(index), kind: 1, zone: UInt8(Self.zones.firstIndex(of: zone) ?? 4), reserved: (0, 0))
        case let .newColumn(targetScreen, after)?:
            guard targetScreen == screen, let index = gaps.firstIndex(of: after) else { return nil }
            return CmuxPaneDropTarget(index: UInt32(index), kind: 2, zone: 4, reserved: (0, 0))
        case let .newDock(targetScreen, edge)?:
            guard targetScreen == screen, let code = Self.edges.firstIndex(of: edge) else { return nil }
            return CmuxPaneDropTarget(index: 0, kind: 3, zone: UInt8(code), reserved: (0, 0))
        case nil:
            return nil
        }
    }

    private func target(_ wire: CmuxPaneDropTarget, screen: ScreenID) -> DropTarget? {
        let index = Int(wire.index)
        switch wire.kind {
        case 1 where index < panes.count && Int(wire.zone) < Self.zones.count:
            return .pane(panes[index], Self.zones[Int(wire.zone)])
        case 2 where index < gaps.count:
            return .newColumn(screen: screen, after: gaps[index])
        case 3 where Int(wire.zone) < Self.edges.count:
            return .newDock(screen: screen, edge: Self.edges[Int(wire.zone)])
        default:
            return nil
        }
    }

    private func ask(screen: ScreenID, previous: DropTarget?,
                     _ call: (UnsafePointer<CmuxPaneDropTarget>?, UnsafeMutablePointer<CmuxPaneDropTarget>) -> Int32) -> DropTarget? {
        var out = CmuxPaneDropTarget()
        let found: Int32
        if let previous = wire(previous, screen: screen) {
            found = withUnsafePointer(to: previous) { call($0, &out) }
        } else {
            found = call(nil, &out)
        }
        return found == 1 ? target(out, screen: screen) : nil
    }

    func target(inContent point: CGPoint, screen: ScreenID, previous: DropTarget?) -> DropTarget? {
        ask(screen: screen, previous: previous) { cmux_pane_drop_target_in_content(handle, Double(point.x), Double(point.y), $0, $1) }
    }

    func target(atView point: CGPoint, offset: CGFloat, screen: ScreenID, previous: DropTarget?) -> DropTarget? {
        ask(screen: screen, previous: previous) { cmux_pane_drop_target(handle, Double(point.x), Double(point.y), Double(offset), $0, $1) }
    }

    func dock(atView point: CGPoint, topInset: CGFloat, bottomInset: CGFloat, screen: ScreenID, previous: DropTarget?) -> DropTarget? {
        ask(screen: screen, previous: previous) {
            cmux_pane_drop_dock(handle, Double(point.x), Double(point.y), Double(topInset), Double(bottomInset), $0, $1)
        }
    }

    func zone(at point: CGPoint, in rect: CGRect, header: CGFloat, footer: CGFloat, previous: PaneDropZone?) -> PaneDropZone {
        let cell = CmuxPaneDropRect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
        let shown = previous.flatMap { Self.zones.firstIndex(of: $0) }.map { UInt8($0) } ?? 255
        var out: UInt8 = 4
        guard cmux_pane_drop_zone(handle, Double(point.x), Double(point.y), cell, Double(header), Double(footer), shown, &out) == 1,
              Int(out) < Self.zones.count else { return .center }
        return Self.zones[Int(out)]
    }

    /// What `target`'s preview fills in view space with the strip at `offset`; `body` for a pane's.
    func rects(for target: DropTarget, offset: CGFloat) -> (highlight: CGRect, region: CGRect, body: CGRect?)? {
        // The screen id only matters for a previous target; a target here names its own.
        let screen: ScreenID
        switch target {
        case let .newColumn(own, _), let .newDock(own, _): screen = own
        case .pane: screen = ScreenID("")
        }
        guard var wire = wire(target, screen: screen) else { return nil }
        var out = CmuxPaneDropRects()
        guard cmux_pane_drop_rects(handle, &wire, Double(offset), &out) == 1 else { return nil }
        func rect(_ r: CmuxPaneDropRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
        return (rect(out.highlight), rect(out.region), out.has_body == 1 ? rect(out.body) : nil)
    }
}

nonisolated private extension DropScreen {
    /// The screen JSON (`pane_drop_zones::Screen`).
    nonisolated struct Request: Encodable {
        nonisolated struct Rect: Encodable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double
            init(x: Double, y: Double, width: Double, height: Double) { (self.x, self.y, self.width, self.height) = (x, y, width, height) }
            init(_ rect: CGRect) { self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height)) }
        }
        nonisolated struct Pane: Encodable {
            var rect: Rect
            var fixed: Bool
            var header: Double
            var footer: Double
        }
        nonisolated struct Dock: Encodable {
            var edge: String
            var frame: Rect
            var cover: Rect
        }
        nonisolated struct Style: Encodable {
            var edgeFraction: Double
            var edgeMinimum: Double
            var edgeMaximum: Double
            var hysteresis: Double
            var dockBand: Double
            var dockTopBand: Double
            var panePadding: Double
            var stripGap: Double
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
