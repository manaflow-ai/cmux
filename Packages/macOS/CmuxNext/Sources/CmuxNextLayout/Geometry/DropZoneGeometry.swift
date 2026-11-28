public import CoreGraphics

/// Hit testing and highlight rects for tab drops. The rules (zones, gaps, dock bands, previews) are
/// cmux-layout-reducer's `pane_drop_zones`, run over the app FFI's `cmux_pane_drop_*` calls with a screen handle
/// built from the geometry (`DropScreen`); nothing here decides but the shared edge join and the classic overlay.
public nonisolated enum DropZoneGeometry {
    /// The zone of pane cell `rect` under `point` (pane-drop-targets DESIGN.md (c)): the zones divide the pane body
    /// below its `header`-point tab bar (flipped, y grows down); over the tab bar a tab joins the pane (center).
    /// `previous` is the zone the preview shows in this pane now: it holds until the pointer is
    /// `dropZoneHysteresis` past its line.
    public static func zone(at point: CGPoint, in rect: CGRect, header: CGFloat = 0, footer: CGFloat = 0, style: LayoutStyle,
                            previous: PaneDropZone? = nil) -> PaneDropZone {
        DropScreen.shared(geometry: nil, headers: [:], footers: [:], style: style)?.zone(at: point, in: rect, header: header, footer: footer, previous: previous) ?? .center
    }

    /// Drop target under `point` (content space). Column gap zones win over pane edges so "new column" is
    /// reachable between columns; a point in no pane goes to the nearest pane, with its own zone hysteresis.
    public static func target(at point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, headers: [PaneID: CGFloat] = [:],
                              footers: [PaneID: CGFloat] = [:], style: LayoutStyle, previous: DropTarget? = nil) -> DropTarget? {
        DropScreen.shared(geometry: geometry, headers: headers, footers: footers, style: style)?
            .target(inContent: point, screen: screen, previous: previous)
    }

    /// bonsplit's shared edge (#22287): a terminal tab dragged out of
    /// `source` onto the band of the pane beside it that faces `source`
    /// joins that pane instead of splitting it; the pane's outer edge still
    /// splits. Only left and right, as in bonsplit. `frames` are the panes
    /// in one logical line (`ScreenContentView.navigationFrames`); the
    /// neighbor is `FocusNavigation`'s, and must overlap `source` vertically
    /// (its fallback to the nearest pane shares no edge).
    public static func joiningSharedEdge(_ target: DropTarget, from source: PaneID?, frames: [PaneID: CGRect]) -> DropTarget {
        guard let source, case let .pane(pane, zone) = target, pane != source else { return target }
        let toward: LayoutDirection
        switch zone {
        case .left: toward = .right
        case .right: toward = .left
        case .top, .bottom, .center: return target
        }
        guard let from = frames[source], let to = frames[pane], min(from.maxY, to.maxY) > max(from.minY, to.minY),
              FocusNavigation.neighbor(of: source, direction: toward, frames: frames) == pane else { return target }
        return .pane(pane, .center)
    }

    /// Drop target under `point` in view coordinates, with the strip scrolled to `offset`. Docked columns sit above
    /// the strip: their panes take the drop, and the rest of what a docked column covers goes to the nearest docked
    /// pane. `previous` is the target the preview shows now: pane zones hold near their lines, and gaps grow while
    /// shown or shrink for entry from a split zone, using `dropZoneHysteresis`.
    public static func target(atView point: CGPoint, offset: CGFloat, screen: ScreenID, geometry: ScreenGeometry,
                              headers: [PaneID: CGFloat] = [:], footers: [PaneID: CGFloat] = [:], style: LayoutStyle,
                              previous: DropTarget? = nil) -> DropTarget? {
        DropScreen.shared(geometry: geometry, headers: headers, footers: footers, style: style)?
            .target(atView: point, offset: offset, screen: screen, previous: previous)
    }

    /// DD1: an edge band that opens a dock, while that edge has none (view coordinates). Nil elsewhere.
    /// `topInset` is the tab bar height at the top edge, `bottomInset` the same at the bottom (R109).
    public static func dockTarget(atView point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, headers: [PaneID: CGFloat] = [:],
                                  footers: [PaneID: CGFloat] = [:], style: LayoutStyle, topInset: CGFloat = 0, bottomInset: CGFloat = 0,
                                  previous: DropTarget? = nil) -> DropTarget? {
        DropScreen.shared(geometry: geometry, headers: headers, footers: footers, style: style)?
            .dock(atView: point, topInset: topInset, bottomInset: bottomInset, screen: screen, previous: previous)
    }

    /// Classic cmux's pane drop overlay (`compactOverlayFrame`, padding 4):
    /// the pane body below its tab bar inset 4 pt for center; a half for an
    /// edge, inset 4 pt on its three outer sides and meeting the midline.
    /// The half is the size the split gives the new pane (0.5).
    /// The inset of a pane zone's highlight inside the pane's body (classic cmux's 4 pt); its
    /// corner is the pane's less this (`LayoutRootView` tab drops, `ConcentricCorners`).
    public static let classicPanePadding: CGFloat = 4

    public static func classicPaneHighlight(body: CGRect, zone: PaneDropZone, padding: CGFloat = classicPanePadding) -> CGRect {
        let (x, y, w, h) = (body.minX, body.minY, body.width, body.height)
        let rect: CGRect = switch zone {
        case .center: CGRect(x: x + padding, y: y + padding, width: w - padding * 2, height: h - padding * 2)
        case .left: CGRect(x: x + padding, y: y + padding, width: body.midX - x - padding, height: h - padding * 2)
        case .right: CGRect(x: body.midX, y: y + padding, width: body.maxX - body.midX - padding, height: h - padding * 2)
        case .top: CGRect(x: x + padding, y: y + padding, width: w - padding * 2, height: body.midY - y - padding)
        case .bottom: CGRect(x: x + padding, y: body.midY, width: w - padding * 2, height: body.maxY - body.midY - padding)
        }
        return CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width), height: max(0, rect.height))
    }

    /// `target`'s whole region (the pane's content rect, the column gap zone, the new dock) in view coordinates with
    /// the strip at `offset`. Pass the `headers` and `footers` the other calls get, so one screen handle serves them all.
    public static func regionRectInView(for target: DropTarget, offset: CGFloat, geometry: ScreenGeometry, headers: [PaneID: CGFloat] = [:],
                                        footers: [PaneID: CGFloat] = [:], style: LayoutStyle) -> CGRect? {
        DropScreen.shared(geometry: geometry, headers: headers, footers: footers, style: style)?
            .rects(for: target, offset: offset)?.region
    }

    /// Where the glass highlight goes for `target` in view coordinates with the strip at `offset`.
    public static func highlightRectInView(for target: DropTarget, offset: CGFloat, geometry: ScreenGeometry,
                                           headers: [PaneID: CGFloat] = [:], footers: [PaneID: CGFloat] = [:],
                                           style: LayoutStyle) -> CGRect? {
        DropScreen.shared(geometry: geometry, headers: headers, footers: footers, style: style)?
            .rects(for: target, offset: offset)?.highlight
    }

    /// `pane`'s body in view coordinates: its content rect below its tab bar (and above a bottom tab bar), the area
    /// its drop zones divide.
    public static func paneBody(of pane: PaneID, offset: CGFloat, geometry: ScreenGeometry, headers: [PaneID: CGFloat],
                                footers: [PaneID: CGFloat], style: LayoutStyle) -> CGRect? {
        DropScreen.shared(geometry: geometry, headers: headers, footers: footers, style: style)?
            .rects(for: .pane(pane, .center), offset: offset)?.body
    }
}
