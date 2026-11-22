public import CoreGraphics
import CCmuxLayoutReducerFFI
import Foundation

/// Swift model adapter for the shared Rust sidebar drop reducer.
public nonisolated enum DropResolver {
    public static var groupEdgeFraction: CGFloat { SidebarTunables.groupEdgeFraction.value }
    public static var groupExitFraction: CGFloat { SidebarTunables.groupExitFraction.value }
    public static var sectionTopFraction: CGFloat { SidebarTunables.sectionTopFraction.value }

    public static func baseY(forDisplayY y: CGFloat, gapY: CGFloat?, gapHeight: CGFloat) -> CGFloat? {
        var base = 0.0
        guard cmux_sidebar_base_y(Double(y), gapY == nil ? 0 : 1, Double(gapY ?? 0), Double(gapHeight), &base) == 1 else { return nil }
        return CGFloat(base)
    }

    /// The tunable onto band (start, end) of a loose workspace row.
    public static var ontoBand: (start: CGFloat, end: CGFloat) {
        (SidebarTunables.workspaceOntoStart.value, SidebarTunables.workspaceOntoEnd.value)
    }

    /// Every tunable a drag's rules hold (`DragRules`, `TabDragRules`): a change makes the rules again.
    static var tunables: [CGFloat] { [groupEdgeFraction, groupExitFraction, sectionTopFraction, ontoBand.start, ontoBand.end] }

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

    /// An internal drag's drop rules in the shared reducer (`cmux_sidebar_drag_*`): the base rows and sections cross
    /// once, when the drag's base is laid out, and each move crosses with the card's points only. A move whose answer
    /// did not change decodes nothing. Over a loose workspace row that can take an onto-drop the card's centre decides,
    /// elsewhere its leading edge (`sidebar_drag::resolve_drag`, spec amendment 1780d02). Used on the main thread.
    public final class DragRules {
        private let handle: OpaquePointer
        private var last: (target: DropTarget?, probe: DragProbe)?

        public init?(payload: DragPayload, base: SidebarLayout, sections: [SidebarSection], ungroupedFirst: Bool = false) {
            let band = DropResolver.ontoBand
            let request = RustDropRequest(y: 0, payload: RustPayload(payload), rows: RustRow.resolvable(base.rows), sections: RustSection.resolvable(sections),
                                          ungroupedFirst: ungroupedFirst, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction),
                                          sectionTopFraction: Double(sectionTopFraction), workspaceOntoStart: Double(band.start), workspaceOntoEnd: Double(band.end))
            guard let handle = RustSidebarClient.handle(request, { cmux_sidebar_drag_new($0, $1) }) else { return nil }
            self.handle = handle
        }

        deinit { cmux_sidebar_drag_free(handle) }

        /// `centreY`/`leadingY` are displayed y values; `gapY`/`gapHeight` the open gap they are drawn around. Nil keeps
        /// the last target (neither point can decide, or the centre is in the gap and the leading edge finds no slot the
        /// rows can take).
        public func resolve(centreY: CGFloat, leadingY: CGFloat, gapY: CGFloat?, gapHeight: CGFloat) -> (target: DropTarget?, probe: DragProbe)? {
            let handle = handle
            switch RustSidebarClient.move(as: RustDrag?.self, { cmux_sidebar_drag_resolve(handle, Double(centreY), Double(leadingY), gapY == nil ? 0 : 1,
                                                                                         Double(gapY ?? 0), Double(gapHeight), $0, $1, $2) }) {
            case .same: break
            case let .value(drag): last = drag.flatMap { drag in drag.swiftProbe.map { (drag.target?.swiftValue, $0) } }
            case .failed: last = nil
            }
            return last
        }
    }

    /// A tab drag's drop rules in the shared reducer (`cmux_sidebar_tab_drag_*`): the base rows and sections cross once
    /// per drag, each move with its base-layout y only. Used on the main thread.
    public final class TabDragRules {
        private let handle: OpaquePointer
        private var drop: SidebarTabDrop?, wholeRowDrop: SidebarTabDrop?
        private var refusal: (row: SidebarRowKey, reason: SidebarTabDropRefusal)?

        public init?(base: SidebarLayout, sections: [SidebarSection], sourceMachine: MachineID?) {
            let request = RustTabRequest(y: 0, rows: RustRow.resolvable(base.rows, keepsFoldRows: true, soleRowsAsHeaders: false), sections: RustSection.resolvable(sections),
                                         sourceMachine: sourceMachine?.rawValue, groupEdgeFraction: Double(groupEdgeFraction), groupExitFraction: Double(groupExitFraction),
                                         sectionTopFraction: Double(sectionTopFraction))
            guard let handle = RustSidebarClient.handle(request, { cmux_sidebar_tab_drag_new($0, $1) }) else { return nil }
            self.handle = handle
        }

        deinit { cmux_sidebar_tab_drag_free(handle) }

        /// The tab drop at base-layout `y`. `wholeRows`: a workspace row takes the tab over its whole height (no slot at its edges).
        public func drop(y: CGFloat, wholeRows: Bool = false) -> SidebarTabDrop? {
            let handle = handle
            let reply = RustSidebarClient.move(as: RustTabDrop?.self, { cmux_sidebar_tab_drag_drop(handle, Double(y), wholeRows ? 1 : 0, $0, $1, $2) })
            var answer = wholeRows ? wholeRowDrop : drop
            switch reply {
            case .same: break
            case let .value(tab): answer = tab?.swiftValue
            case .failed: answer = nil
            }
            if wholeRows { wholeRowDrop = answer } else { drop = answer }
            return answer
        }

        /// Why no tab drop is possible at base-layout `y`: the refused row and the reason.
        public func refusal(y: CGFloat) -> (row: SidebarRowKey, reason: SidebarTabDropRefusal)? {
            let handle = handle
            switch RustSidebarClient.move(as: RustTabRefusal?.self, { cmux_sidebar_tab_drag_refusal(handle, Double(y), $0, $1, $2) }) {
            case .same: break
            case let .value(refusal): self.refusal = refusal.flatMap { refusal in refusal.row.swiftValue.flatMap { row in refusal.swiftReason.map { (row, $0) } } }
            case .failed: refusal = nil
            }
            return refusal
        }
    }
}
