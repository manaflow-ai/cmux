public import CoreGraphics
import Foundation
#if CMUX_LAYOUT_REDUCER_FFI
import CCmuxLayoutReducerFFI
#endif

/// Swift model adapter for the shared Rust sidebar drop reducer.
public nonisolated enum DropResolver {
    public static var groupEdgeFraction: CGFloat { SidebarTunables.groupEdgeFraction.value }
    public static var groupExitFraction: CGFloat { SidebarTunables.groupExitFraction.value }
    public static var sectionTopFraction: CGFloat { SidebarTunables.sectionTopFraction.value }

    public static func baseY(forDisplayY y: CGFloat, gapY: CGFloat?, gapHeight: CGFloat) -> CGFloat? {
        let request = RustBaseY(displayY: Double(y), gapY: gapY.map(Double.init), gapHeight: Double(gapHeight))
        return RustSidebarClient.call("base_y", request, as: Double.self).map { CGFloat($0) }
    }

    public static func resolve(y: CGFloat, payload: DragPayload, base: SidebarLayout, sections: [SidebarSection], ungroupedFirst: Bool = false) -> DropTarget? {
        let request = RustDropRequest(y: Double(y), payload: RustPayload(payload), rows: base.rows.map(RustRow.init), sections: sections.map(RustSection.init), ungroupedFirst: ungroupedFirst, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction), sectionTopFraction: Double(sectionTopFraction))
        return RustSidebarClient.call("resolve", request, as: RustTarget.self)?.swiftValue
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
