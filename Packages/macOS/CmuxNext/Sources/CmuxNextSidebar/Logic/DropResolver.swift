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
        let request = RustDropRequest(y: Double(y), payload: RustPayload(payload), rows: base.rows.map(RustRow.init), sections: sections.map(RustSection.init), ungroupedFirst: ungroupedFirst, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction), sectionTopFraction: Double(sectionTopFraction),
                                      workspaceOntoStart: Double(band.start),
                                      workspaceOntoEnd: Double(band.end))
        return RustSidebarClient.call("resolve", request, as: RustTarget.self)?.swiftValue
    }

    /// Which point of the lifted card decided a drag's drop.
    public enum DragProbe: String, Sendable { case centre, leadingEdge }

    /// Resolves an internal drag from the lifted card (spec amendment
    /// 1780d02, centre band). Over a loose workspace row that can take an
    /// onto-drop, the card's centre decides: the onto band groups, above it
    /// the drop goes before the row, below it after. Elsewhere (group rows,
    /// rows inside a group, a group drag) the card's leading edge decides
    /// (nxdog30: a row makes way once the card covers half of it).
    /// `centreY`/`leadingY` are base-layout y values, nil inside the gap.
    /// Returns nil when neither point can decide (keep the last target).
    public static func resolveDrag(centreY: CGFloat?, leadingY: CGFloat?, payload: DragPayload, base: SidebarLayout,
                                   sections: [SidebarSection], ungroupedFirst: Bool = false) -> (target: DropTarget?, probe: DragProbe)? {
        let band = ontoBand
        let off: (start: CGFloat, end: CGFloat) = (0, 0)
        if band.start < band.end, let centreY {
            let target = resolve(y: centreY, payload: payload, base: base, sections: sections, ungroupedFirst: ungroupedFirst, onto: band)
            if case .ontoWorkspace? = target { return (target, .centre) }
            // A whole-row band asks whether the row under the centre could take an onto-drop.
            if case .ontoWorkspace? = resolve(y: centreY, payload: payload, base: base, sections: sections, ungroupedFirst: ungroupedFirst, onto: (0, 1)) {
                return (resolve(y: centreY, payload: payload, base: base, sections: sections, ungroupedFirst: ungroupedFirst, onto: off), .centre)
            }
        }
        guard let leadingY else { return nil }
        return (resolve(y: leadingY, payload: payload, base: base, sections: sections, ungroupedFirst: ungroupedFirst, onto: off), .leadingEdge)
    }

    public static func resolveTabDrop(y: CGFloat, base: SidebarLayout, sections: [SidebarSection], sourceMachine: MachineID?) -> SidebarTabDrop? {
        let request = RustTabRequest(y: Double(y), rows: base.rows.map(RustRow.init), sections: sections.map(RustSection.init), sourceMachine: sourceMachine?.rawValue, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction), sectionTopFraction: Double(sectionTopFraction), tabIntoStart: 0.25, tabIntoEnd: 0.75)
        return RustSidebarClient.call("tab_drop", request, as: RustTabDrop.self)?.swiftValue
    }

    public static func tabDropRefusal(y: CGFloat, base: SidebarLayout, sections: [SidebarSection], sourceMachine: MachineID?) -> (row: SidebarRowKey, reason: SidebarTabDropRefusal)? {
        let request = RustTabRequest(y: Double(y), rows: base.rows.map(RustRow.init), sections: sections.map(RustSection.init), sourceMachine: sourceMachine?.rawValue, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction), sectionTopFraction: Double(sectionTopFraction), tabIntoStart: 0.25, tabIntoEnd: 0.75)
        guard let refusal = RustSidebarClient.call("tab_refusal", request, as: RustTabRefusal.self), let row = refusal.row.swiftValue, let reason = refusal.swiftReason else { return nil }
        return (row, reason)
    }
}
