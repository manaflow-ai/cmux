import AppKit
import Bonsplit

/// Drives every pane-divider drag claimed by a portal host. A single-axis
/// band captures one split view; a nested corner captures its vertical and
/// horizontal split views together. Each update writes
/// the divider position through the owning `BonsplitController`'s model
/// first (`setDividerPosition(_:forSplit:)` via `BonsplitManagedSplitView`)
/// and then moves the view with `setPosition`. Bonsplit's coordinators
/// cannot latch their pointer-based drag detection for a corner drag — the
/// pointer legitimately sits outside one split view's bounds when it is
/// past the other divider — so any model reassert they run must already see
/// our value; writing the model first guarantees that instead of fighting
/// the latch.
@MainActor
final class PortalDividerDragController {
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
    private(set) var cursorKind: PortalDividerCursorKind?

    var isActive: Bool { !axes.isEmpty }

    func begin(atWindowPoint windowPoint: NSPoint, regions: [PortalSplitDividerRegion]) -> Bool {
        guard !isActive,
              let drag = Self.drag(atWindowPoint: windowPoint, regions: regions) else {
            return false
        }
        var nextAxes: [AxisDrag] = []
        for region in drag.regions {
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
        cursorKind = drag.kind
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        drag.kind.cursor.set()
        return true
    }

    func update(windowPoint: NSPoint) {
        guard isActive, !isAborted else { return }
        cursorKind?.cursor.set()
        for axis in axes {
            // Resizing the first axis can synchronously reconfigure the tree,
            // so revalidate each axis immediately before applying it.
            guard let splitView = axis.resolvedSplitView else {
                // Keep the gesture claimed and stop moving anything until
                // the real mouse-up so the stale click cannot leak anywhere.
                isAborted = true
                return
            }
            let pointer = splitView.convert(windowPoint, from: nil)
            let delta = (axis.isVertical ? pointer.x : pointer.y) - axis.initialPointer
            let proposed = axis.initialPosition + delta
            let clamped = Self.clampedPosition(proposed, in: splitView, dividerIndex: axis.dividerIndex)
            // Model first: a coordinator that classifies the view resize as
            // programmatic synchronously reasserts the model position, so
            // the model must already hold the dragged value.
            if let managed = splitView as? BonsplitManagedSplitView,
               let controller = managed.bonsplitController,
               let splitId = managed.bonsplitSplitId {
                let extent = axis.isVertical ? splitView.bounds.width : splitView.bounds.height
                let available = max(extent - splitView.dividerThickness, 1)
                controller.setDividerPosition(clamped / available, forSplit: splitId)
                cursorKind?.cursor.set()
            }
            splitView.setPosition(clamped, ofDividerAt: axis.dividerIndex)
            cursorKind?.cursor.set()
        }
        cursorKind?.cursor.set()
    }

    func end() {
        guard isActive else { return }
        axes = []
        isAborted = false
        cursorKind = nil
        TerminalWindowPortalRegistry.endInteractiveGeometryResize()
    }

    /// Resolves the exact divider identities captured by a mouse-down. A real
    /// nested corner owns both axes; every other point inside a divider's
    /// single-axis band owns only the topmost divider. Portal hosts use this
    /// same result for hit claiming and drag start, so a cursor is never
    /// advertised by one owner and dragged by another.
    static func drag(
        atWindowPoint windowPoint: NSPoint,
        regions: [PortalSplitDividerRegion]
    ) -> (kind: PortalDividerCursorKind, regions: [PortalSplitDividerRegion])? {
        let hits = PortalSplitDividerRegion.dividerHits(at: windowPoint, in: regions)
        if let aligned = hits.alignedIntersectionRegions {
            return (.both, aligned.vertical + aligned.horizontal)
        }
        guard let region = hits.first else { return nil }
        return (region.isVertical ? .vertical : .horizontal, [region])
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
