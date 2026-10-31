public import CoreGraphics
import Foundation

/// Swift model adapter for the shared Rust sidebar drop reducer.
public nonisolated enum DropResolver {
    public static var groupEdgeFraction: CGFloat { SidebarTunables.groupEdgeFraction.value }
    public static var groupExitFraction: CGFloat { SidebarTunables.groupExitFraction.value }
    public static var sectionTopFraction: CGFloat { SidebarTunables.sectionTopFraction.value }

    public static func baseY(forDisplayY y: CGFloat, gapY: CGFloat?, gapHeight: CGFloat) -> CGFloat? {
        let request = RustBaseY(displayY: Double(y), gapY: gapY.map(Double.init), gapHeight: Double(gapHeight))
        return RustSidebarClient.call("base_y", request, as: Double.self).map { CGFloat($0) }
    }

    /// The tunable onto band (start, end) of a loose workspace row.
    public static var ontoBand: (start: CGFloat, end: CGFloat) {
        (SidebarTunables.workspaceOntoStart.value, SidebarTunables.workspaceOntoEnd.value)
    }

    /// Resolves a drop at `y`. `onto` is the onto band of a loose workspace
    /// row (default: the tunables); an empty band turns grouping off.
    public static func resolve(y: CGFloat, payload: DragPayload, base: SidebarLayout, sections: [SidebarSection], ungroupedFirst: Bool = false,
                               onto: (start: CGFloat, end: CGFloat)? = nil) -> DropTarget? {
        let band = onto ?? ontoBand
        let request = RustDropRequest(y: Double(y), payload: RustPayload(payload), rows: RustRow.resolvable(base.rows), sections: RustSection.resolvable(sections), ungroupedFirst: ungroupedFirst, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction), sectionTopFraction: Double(sectionTopFraction),
                                      workspaceOntoStart: Double(band.start),
                                      workspaceOntoEnd: Double(band.end))
        return RustSidebarClient.call("resolve", request, as: RustTarget.self)?.swiftValue
    }

    /// Which point of the lifted card decided a drag's drop.
    public enum DragProbe: String, Sendable { case centre, leadingEdge }

    /// Resolves an internal drag from the lifted card in one call to the
    /// shared reducer (`sidebar_drag::resolve_drag`, spec amendment 1780d02):
    /// over a loose workspace row that can take an onto-drop the card's
    /// centre decides, elsewhere its leading edge. `centreY`/`leadingY` are
    /// displayed y values; `gapY`/`gapHeight` the open gap they are drawn
    /// around. Nil keeps the last target (neither point can decide, or the
    /// centre is in the gap and the leading edge finds no slot the rows can take).
    public static func resolveDrag(centreY: CGFloat, leadingY: CGFloat, gapY: CGFloat?, gapHeight: CGFloat, payload: DragPayload,
                                   base: SidebarLayout, sections: [SidebarSection], ungroupedFirst: Bool = false) -> (target: DropTarget?, probe: DragProbe)? {
        let band = ontoBand
        let request = RustDragRequest(centreY: Double(centreY), leadingY: Double(leadingY), gapY: gapY.map(Double.init), gapHeight: Double(gapHeight),
                                      payload: RustPayload(payload), rows: RustRow.resolvable(base.rows), sections: RustSection.resolvable(sections),
                                      ungroupedFirst: ungroupedFirst, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction),
                                      sectionTopFraction: Double(sectionTopFraction), workspaceOntoStart: Double(band.start), workspaceOntoEnd: Double(band.end))
        guard let drag = RustSidebarClient.call("resolve_drag", request, as: RustDrag?.self) ?? nil, let probe = drag.swiftProbe else { return nil }
        return (drag.target?.swiftValue, probe)
    }

    /// - Parameter reordersTabRows: a tab drag, whose drop on a tab row's edge goes before that tab.
    /// - Parameter wholeRows: a workspace row takes the tab over its whole height (no slot at its edges).
    public static func resolveTabDrop(y: CGFloat, base: SidebarLayout, sections: [SidebarSection], sourceMachine: MachineID?,
                                      reordersTabRows: Bool = false, wholeRows: Bool = false) -> SidebarTabDrop? {
        var request = RustTabRequest(y: Double(y), rows: RustRow.resolvable(base.rows, preservesTabRows: true), sections: RustSection.resolvable(sections), sourceMachine: sourceMachine?.rawValue, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction), sectionTopFraction: Double(sectionTopFraction), reordersTabRows: reordersTabRows)
        if wholeRows { (request.tabIntoStart, request.tabIntoEnd) = (0, 1) }
        return RustSidebarClient.call("tab_drop", request, as: RustTabDrop.self)?.swiftValue
    }

    public static func tabDropRefusal(y: CGFloat, base: SidebarLayout, sections: [SidebarSection], sourceMachine: MachineID?,
                                      reordersTabRows: Bool = false) -> (row: SidebarRowKey, reason: SidebarTabDropRefusal)? {
        let request = RustTabRequest(y: Double(y), rows: RustRow.resolvable(base.rows, preservesTabRows: true), sections: RustSection.resolvable(sections), sourceMachine: sourceMachine?.rawValue, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction), sectionTopFraction: Double(sectionTopFraction), reordersTabRows: reordersTabRows)
        guard let refusal = RustSidebarClient.call("tab_refusal", request, as: RustTabRefusal.self), let row = refusal.row.swiftValue, let reason = refusal.swiftReason else { return nil }
        return (row, reason)
    }
}
