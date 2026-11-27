public import CoreGraphics

/// Hit testing and highlight rects for tab drops.
public nonisolated enum DropZoneGeometry {
    /// The zone of pane cell `rect` under `point` (pane-drop-targets
    /// DESIGN.md (c), the first-principles rule): the zones divide the pane
    /// body below its `header`-point tab bar (flipped, y grows down); over
    /// the tab bar a tab joins the pane (center). Each edge owns a band
    /// (`band(for:)`); a point inside several bands (a corner) goes to the
    /// edge it is relatively nearest to (depth / band), so a corner splits
    /// along the edge the pointer is closer to; else center. The preview
    /// (`highlightRect`) and the commit both take the target from here
    /// (R47). `previous` is the zone the preview shows in this pane now: it
    /// holds until the pointer is `dropZoneHysteresis` past its line, so a
    /// pointer held on a line never flickers.
    public static func zone(at point: CGPoint, in rect: CGRect, header: CGFloat = 0, footer: CGFloat = 0, style: LayoutStyle,
                            previous: PaneDropZone? = nil) -> PaneDropZone {
        DropZoneRules(style: style).zone(at: point, in: rect, header: header, footer: footer, previous: previous)
    }

    /// Drop target under `point` (content space). Column gap zones win over
    /// pane edges so "new column" is reachable between columns. The shown
    /// gap holds `dropZoneHysteresis` horizontally past its frame; entered
    /// from a left or right split zone it shrinks by at most a quarter of
    /// its width (`gapTarget`). A point in no pane goes to the nearest pane,
    /// with its own zone hysteresis.
    public static func target(at point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, headers: [PaneID: CGFloat] = [:],
                              footers: [PaneID: CGFloat] = [:], style: LayoutStyle, previous: DropTarget? = nil) -> DropTarget? {
        DropZoneRules(screen: screen, geometry: geometry, headers: headers, footers: footers, style: style)
            .target(at: point, previous: previous)
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

    /// Drop target under `point` in view coordinates, with the strip
    /// scrolled to `offset`. Docked columns sit above the strip: their panes
    /// take the drop, and the rest of what a docked column covers (its glass
    /// rim, a docked column's edge band) goes to the nearest docked pane, so
    /// nothing lands in a strip pane hidden under it. The strip resolves as
    /// `target(at:)`. Every point resolves while the screen has a pane.
    /// `previous` is the target the preview shows now: pane zones hold near
    /// their lines, and gaps grow while shown or shrink for entry from a
    /// split zone, using `dropZoneHysteresis` as in `target(at:)`.
    public static func target(atView point: CGPoint, offset: CGFloat, screen: ScreenID, geometry: ScreenGeometry,
                              headers: [PaneID: CGFloat] = [:], footers: [PaneID: CGFloat] = [:], style: LayoutStyle,
                              previous: DropTarget? = nil) -> DropTarget? {
        DropZoneRules(screen: screen, geometry: geometry, headers: headers, footers: footers, style: style)
            .target(atView: point, offset: offset, previous: previous)
    }

    /// DD1: an edge band that opens a dock, while that edge has none (view
    /// coordinates). Nil elsewhere. The top band is `dockTopDropBand` deep,
    /// the bottom `dockDropBand`; the side bands are half `dockDropBand`, so
    /// the outer panes keep their left and right split zones. Top and bottom
    /// win in the corners. The same dock in `previous` grows its band inward
    /// by `dropZoneHysteresis`. Entered from the pane split zone that faces
    /// the same edge (a drag pushing a split toward the window edge), the
    /// band shrinks toward the edge by at most half its depth, so the split
    /// holds near the line; from anywhere else the band keeps its depth.
    /// `topInset` is the tab bar height at the top edge: the tab bar takes
    /// drops into the strip, so the top band starts below it (dogfood
    /// 2026-10-03: a band inside the tab bar was never reached).
    /// `bottomInset` is the same for a tab bar at the bottom (R109).
    public static func dockTarget(atView point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, style: LayoutStyle,
                                  topInset: CGFloat = 0, bottomInset: CGFloat = 0, previous: DropTarget? = nil) -> DropTarget? {
        DropZoneRules(screen: screen, geometry: geometry, style: style)
            .dockTarget(atView: point, topInset: topInset, bottomInset: bottomInset, previous: previous)
    }

    /// The whole region a drop on `target` divides (content space): the
    /// pane's rounded content rect, or the column gap zone.
    public static func regionRect(for target: DropTarget, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect? {
        rects(for: target, offset: geometry.stripMinX, geometry: geometry, style: style)?.region
    }

    /// Classic cmux's pane drop overlay (`compactOverlayFrame`, padding 4):
    /// the pane body below its tab bar inset 4 pt for center; a half for an
    /// edge, inset 4 pt on its three outer sides and meeting the midline.
    /// The half is the size the split gives the new pane (0.5).
    /// The inset of a pane zone's highlight inside the pane's body (classic cmux's 4 pt); its
    /// corner is the pane's less this (`LayoutRootView` tab drops, `ConcentricCorners`).
    public static let classicPanePadding: CGFloat = 4

    public static func classicPaneHighlight(body: CGRect, zone: PaneDropZone, padding: CGFloat = classicPanePadding) -> CGRect {
        DropZoneRules.classicPaneHighlight(body: body, zone: zone, padding: padding)
    }

    /// `regionRect(for:)` in view coordinates with the strip at `offset`.
    public static func regionRectInView(for target: DropTarget, offset: CGFloat, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect? {
        rects(for: target, offset: offset, geometry: geometry, style: style)?.region
    }

    /// `highlightRect(for:)` in view coordinates with the strip at `offset`.
    public static func highlightRectInView(for target: DropTarget, offset: CGFloat, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect? {
        rects(for: target, offset: offset, geometry: geometry, style: style)?.highlight
    }

    /// Where the glass highlight goes for `target` (content space).
    public static func highlightRect(for target: DropTarget, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect? {
        rects(for: target, offset: geometry.stripMinX, geometry: geometry, style: style)?.highlight
    }

    /// A preview's rects (`DropZoneRules.rects(for:offset:)`); the screen names no rect, so any screen asks.
    private static func rects(for target: DropTarget, offset: CGFloat, geometry: ScreenGeometry,
                              style: LayoutStyle) -> (highlight: CGRect, region: CGRect, body: CGRect?)? {
        DropZoneRules(screen: ScreenID(rawValue: ""), geometry: geometry, style: style).rects(for: target, offset: offset)
    }
}
