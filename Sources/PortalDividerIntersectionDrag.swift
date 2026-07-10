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
    // Nested types do not inherit the enclosing class's @MainActor, and
    // `resolvedSplitView` reads MainActor-isolated NSView state.
    @MainActor
    private struct AxisDrag {
        weak var splitView: NSSplitView?
        weak var window: NSWindow?
        let dividerIndex: Int
        let initialPosition: CGFloat
        let initialPointer: CGFloat
        let isVertical: Bool

        /// The captured divider identity is only valid while the split view
        /// stays in its original window with the same orientation and enough
        /// arranged subviews. A pane close or Bonsplit reconfiguration between
        /// drag samples would otherwise feed `setPosition` (and the delegate's
        /// constrain calls) a stale index — an AppKit range exception — or
        /// resize a different divider than the one grabbed.
        var resolvedSplitView: NSSplitView? {
            guard let splitView, let window,
                  splitView.window === window,
                  splitView.isVertical == isVertical,
                  dividerIndex + 1 < splitView.arrangedSubviews.count else {
                return nil
            }
            return splitView
        }
    }

    private var axes: [AxisDrag] = []
    private var isAborted = false

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
                window: splitView.window,
                dividerIndex: region.dividerIndex,
                initialPosition: region.isVertical ? dividerRect.origin.x : dividerRect.origin.y,
                initialPointer: region.isVertical ? pointer.x : pointer.y,
                isVertical: region.isVertical
            ))
        }
        axes = nextAxes
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        // Arm the coordinators' interactive-drag latch while the mouseDown
        // pointer is still inside both divider bands: bonsplit latches from
        // `splitViewWillResizeSubviews` only when the live pointer event is
        // over the divider, so a fast first drag sample could otherwise be
        // classified as a programmatic resize and snapped back to the model.
        reassertCurrentPositions()
        PortalDividerCursorKind.both.cursor.set()
        return true
    }

    func update(windowPoint: NSPoint) {
        guard isActive, !isAborted else { return }
        for axis in axes {
            // Resizing the first axis can synchronously reconfigure the tree,
            // so revalidate each axis immediately before applying it.
            guard let splitView = axis.resolvedSplitView else {
                // Keep the gesture claimed and stop moving anything: the
                // button is still down, so running the latch-clearing
                // reassert now would read as part of the drag. `end()` runs
                // the handshake at the real mouse-up instead.
                isAborted = true
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
        // Resize once more now that the button is released so the
        // coordinators' resize observers see a non-drag resize and clear
        // their interactive-drag latch (the host consumes the mouseUp, so no
        // native divider tracking runs this handshake for us).
        reassertCurrentPositions()
        axes = []
        isAborted = false
        TerminalWindowPortalRegistry.endInteractiveGeometryResize()
    }

    /// Re-applies each axis's current divider position. Positions do not
    /// change; the point is the `NSSplitView` will/didResize delegate cycle
    /// this triggers, which lets the owning coordinators latch or clear their
    /// interactive-drag state against the current pointer/button state.
    private func reassertCurrentPositions() {
        for axis in axes {
            guard let splitView = axis.resolvedSplitView,
                  let dividerRect = PortalSplitDividerRegion.dividerRect(
                      in: splitView,
                      dividerIndex: axis.dividerIndex
                  ) else { continue }
            let position = axis.isVertical ? dividerRect.origin.x : dividerRect.origin.y
            splitView.setPosition(position, ofDividerAt: axis.dividerIndex)
        }
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
