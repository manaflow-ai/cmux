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

    @MainActor
    private final class DragSession {
        var axes: [AxisDrag]
        let cursorKind: PortalDividerCursorKind
        weak var window: NSWindow?
        var isAborted = false
        var cursorEventMonitor: Any?

        init(axes: [AxisDrag], cursorKind: PortalDividerCursorKind, window: NSWindow) {
            self.axes = axes
            self.cursorKind = cursorKind
            self.window = window
        }
    }

    private enum Phase {
        case idle
        case dragging(DragSession)
    }

    private var phase: Phase = .idle

    private var activeSession: DragSession? {
        guard case .dragging(let session) = phase else { return nil }
        return session
    }

    var cursorKind: PortalDividerCursorKind? { activeSession?.cursorKind }

    var isActive: Bool { activeSession != nil }

#if DEBUG
    var hasCursorEventMonitorForTesting: Bool {
        activeSession?.cursorEventMonitor != nil
    }
#endif

    func begin(atWindowPoint windowPoint: NSPoint, regions: [PortalSplitDividerRegion]) -> Bool {
        guard !isActive,
              let drag = Self.drag(atWindowPoint: windowPoint, regions: regions) else {
            return false
        }
        var nextAxes: [AxisDrag] = []
        var dragWindow: NSWindow?
        for region in drag.regions {
            guard let splitView = region.splitView,
                  let window = splitView.window,
                  let dividerRect = PortalSplitDividerRegion.dividerRect(
                      in: splitView,
                      dividerIndex: region.dividerIndex
                  ) else {
                return false
            }
            if let dragWindow, dragWindow !== window { return false }
            dragWindow = window
            let pointer = splitView.convert(windowPoint, from: nil)
            nextAxes.append(AxisDrag(
                splitView: splitView,
                window: window,
                dividerIndex: region.dividerIndex,
                initialPosition: region.isVertical ? dividerRect.origin.x : dividerRect.origin.y,
                initialPointer: region.isVertical ? pointer.x : pointer.y,
                isVertical: region.isVertical
            ))
        }
        guard let dragWindow else { return false }
        let session = DragSession(axes: nextAxes, cursorKind: drag.kind, window: dragWindow)
        phase = .dragging(session)
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        installCursorEventMonitor(for: session)
        session.cursorKind.cursor.set()
        return true
    }

    func update(windowPoint: NSPoint) {
        guard let session = activeSession, !session.isAborted else { return }
        for axis in session.axes {
            // Resizing the first axis can synchronously reconfigure the tree,
            // so revalidate each axis immediately before applying it.
            guard let splitView = axis.resolvedSplitView else {
                // Keep the gesture claimed and stop moving anything until
                // the real mouse-up so the stale click cannot leak anywhere.
                session.isAborted = true
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
            }
            splitView.setPosition(clamped, ofDividerAt: axis.dividerIndex)
        }
    }

    func end() {
        guard let session = activeSession else { return }
        if let monitor = session.cursorEventMonitor {
            NSEvent.removeMonitor(monitor)
            session.cursorEventMonitor = nil
        }
        phase = .idle
        TerminalWindowPortalRegistry.endInteractiveGeometryResize()
    }

    /// The claimed drag session is the sole cursor owner from mouse-down
    /// through mouse-up. Consuming cursor-only events prevents terminal,
    /// browser, tab-bar, and native split tracking areas from replacing the
    /// latched resize cursor while the button remains down.
    private func installCursorEventMonitor(for session: DragSession) {
        session.cursorEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .mouseEntered,
                .mouseExited,
                .cursorUpdate,
                .appKitDefined,
                .systemDefined,
                .leftMouseDragged,
                .leftMouseUp,
            ]
        ) { [weak self, weak session] event in
            MainActor.assumeIsolated {
                guard let self,
                      let session,
                      self.activeSession === session else {
                    return event
                }

                if let eventWindow = event.window,
                   let dragWindow = session.window,
                   eventWindow !== dragWindow {
                    return event
                }

                session.cursorKind.cursor.set()
                switch event.type {
                case .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate, .appKitDefined, .systemDefined:
                    return nil
                case .leftMouseUp:
                    // AppKit normally sends mouse-up back to the view that
                    // received mouse-down. End on the next MainActor turn as
                    // a lifecycle fallback if that view disappears mid-drag.
                    Task { @MainActor [weak self, weak session] in
                        guard let self, let session, self.activeSession === session else { return }
                        self.end()
                    }
                    return event
                default:
                    return event
                }
            }
        }
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
