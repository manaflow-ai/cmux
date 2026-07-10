import AppKit

/// Drives a two-axis divider drag started at the intersection of a vertical
/// and a horizontal divider band. The terminal portal host view claims the
/// mouseDown at the intersection square and forwards pointer deltas here;
/// this controller converts them into `NSSplitView.setPosition` calls on
/// both split views. Bonsplit's coordinators observe those resizes exactly
/// like a native single-axis drag (their `splitViewWillResizeSubviews` latch
/// keys off the live pointer event over the divider) and persist positions.
@MainActor
final class PortalDividerIntersectionDragController {
    private struct AxisDrag {
        weak var splitView: NSSplitView?
        let dividerIndex: Int
        let initialPosition: CGFloat
        let initialPointer: CGFloat
        let isVertical: Bool
    }

    private var axes: [AxisDrag] = []

    var isActive: Bool { !axes.isEmpty }

    func begin(atWindowPoint windowPoint: NSPoint, regions: [PortalSplitDividerRegion]) -> Bool {
        guard !isActive,
              let intersection = PortalSplitDividerRegion.dividerIntersection(at: windowPoint, in: regions) else {
            return false
        }
        var nextAxes: [AxisDrag] = []
        for region in [intersection.vertical, intersection.horizontal] {
            guard let splitView = region.splitView,
                  let dividerRect = PortalSplitDividerRegion.dividerRect(
                      in: splitView,
                      dividerIndex: region.dividerIndex
                  ) else {
                return false
            }
            let pointer = splitView.convert(windowPoint, from: nil)
            nextAxes.append(AxisDrag(
                splitView: splitView,
                dividerIndex: region.dividerIndex,
                initialPosition: region.isVertical ? dividerRect.origin.x : dividerRect.origin.y,
                initialPointer: region.isVertical ? pointer.x : pointer.y,
                isVertical: region.isVertical
            ))
        }
        axes = nextAxes
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        PortalDividerCursorKind.both.cursor.set()
        return true
    }

    func update(windowPoint: NSPoint) {
        guard isActive else { return }
        for axis in axes {
            guard let splitView = axis.splitView, splitView.window != nil else {
                end()
                return
            }
            let pointer = splitView.convert(windowPoint, from: nil)
            let delta = (axis.isVertical ? pointer.x : pointer.y) - axis.initialPointer
            let proposed = axis.initialPosition + delta
            let clamped = Self.clampedPosition(proposed, in: splitView, dividerIndex: axis.dividerIndex)
            splitView.setPosition(clamped, ofDividerAt: axis.dividerIndex)
        }
        PortalDividerCursorKind.both.cursor.set()
    }

    func end() {
        guard isActive else { return }
        axes = []
        TerminalWindowPortalRegistry.endInteractiveGeometryResize()
    }

    /// `setPosition` does not consult the delegate's constrain methods, so
    /// apply the same min/max the delegate would enforce for a native drag.
    static func clampedPosition(_ proposed: CGFloat, in splitView: NSSplitView, dividerIndex: Int) -> CGFloat {
        var position = proposed
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        if let delegate = splitView.delegate {
            if let minPosition = delegate.splitView?(splitView, constrainMinCoordinate: 0, ofSubviewAt: dividerIndex) {
                position = max(position, minPosition)
            }
            if let maxPosition = delegate.splitView?(splitView, constrainMaxCoordinate: extent, ofSubviewAt: dividerIndex) {
                position = min(position, maxPosition)
            }
        }
        return min(max(position, 0), extent)
    }
}
