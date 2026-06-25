public import AppKit
import ObjectiveC

private var browserPortalInteractiveSplitDividerDragKey: UInt8 = 0

private extension NSWindow {
    /// Per-window latch recording that the user is mid-drag on an app-layout
    /// split divider.
    ///
    /// Stored as an associated object so the latch travels with the window
    /// without adding a stored property to a window subclass. Reading it clears
    /// the latch as soon as the left mouse button is no longer held, so a stale
    /// `true` cannot survive past the drag that set it (e.g. a drag that ended
    /// while the cursor was outside the window).
    var browserPortalHasInteractiveSplitDividerDrag: Bool {
        get {
            let isActive =
                (objc_getAssociatedObject(self, &browserPortalInteractiveSplitDividerDragKey) as? NSNumber)?
                    .boolValue ?? false
            guard isActive else { return false }
            guard (NSEvent.pressedMouseButtons & 1) != 0 else {
                objc_setAssociatedObject(
                    self,
                    &browserPortalInteractiveSplitDividerDragKey,
                    NSNumber(value: false),
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
                return false
            }
            return true
        }
        set {
            objc_setAssociatedObject(
                self,
                &browserPortalInteractiveSplitDividerDragKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

/// Decides whether an `NSSplitView` resize observed by a browser window portal
/// is an external (app-layout) geometry change that warrants a full portal
/// re-sync, or an interaction the portal should leave alone.
///
/// The browser window portal observes `NSSplitView.didResizeSubviewsNotification`
/// for every split view in the window. Two resizes must be filtered out:
///
/// - Resizes inside WebKit's attached DevTools, which uses internal
///   `NSSplitView` instances for the side/bottom inspector layout. Those are
///   local to hosted content and never need a portal-wide re-sync.
/// - Resizes the portal's own browser host anchors already coalesce while the
///   user actively drags an app-layout divider. Re-running the external-geometry
///   sync on the same drag frame doubles up WebKit refresh work and shows up as
///   visible flicker in browser panes.
///
/// To suppress the second case the detector watches
/// `NSSplitView.willResizeSubviewsNotification` and latches a per-window flag
/// (``noteInteractiveSplitDividerDragIfNeeded(_:window:hostView:)``) when the
/// current mouse event lands on an app-layout divider's hit rect. The latch is
/// keyed to the window via an associated object, so it lives with the window
/// rather than the portal and clears automatically once the left button is
/// released.
///
/// The detector is a value type holding no state; callers construct it inline at
/// each notification. All reads (`NSApp.currentEvent`, pressed mouse buttons,
/// `ProcessInfo.systemUptime`, split-view frames) are framework reads, and the
/// only write is the per-window associated-object latch.
public struct SplitDividerDragDetector {
    /// Creates a detector. The detector holds no state; it is a value type so
    /// callers can construct it inline at each notification.
    public init() {}

    /// Returns whether a split resize should be treated as an external,
    /// app-layout geometry change that warrants a full portal re-sync.
    ///
    /// Resizes for split views in another window, split views descended from the
    /// portal's `hostView` (WebKit DevTools internal splits), and resizes that
    /// coincide with an active interactive divider drag are excluded.
    /// - Parameters:
    ///   - splitView: The split view that emitted the resize.
    ///   - window: The portal's window.
    ///   - hostView: The portal's host view, used to detect hosted DevTools splits.
    /// - Returns: `true` when the portal should run its external-geometry sync.
    public func shouldTreatSplitResizeAsExternalGeometry(
        _ splitView: NSSplitView,
        window: NSWindow,
        hostView: NSView
    ) -> Bool {
        guard splitView.window === window else { return false }
        // WebKit's attached DevTools uses internal NSSplitView instances for the
        // side/bottom inspector layout. Those resizes are local to hosted content
        // and should not trigger a full portal re-sync/refresh pass.
        guard !splitView.isDescendant(of: hostView) else { return false }
        // Browser host anchors already emit coalesced geometry callbacks while the
        // user drags a split divider. Running the portal-wide external-geometry
        // sync on the same drag frame doubles up WebKit refresh work and shows up
        // as visible flicker in browser panes.
        return !isInteractiveSplitDividerDrag(in: window)
    }

    /// Latches the per-window interactive-divider-drag flag when the current
    /// mouse event is a left-button press/drag landing on the hit rect of an
    /// app-layout divider in `splitView`.
    ///
    /// Called from the portal's `NSSplitView.willResizeSubviewsNotification`
    /// observer so the latch is set before the matching
    /// `didResizeSubviewsNotification` consults it.
    /// - Parameters:
    ///   - splitView: The split view about to resize.
    ///   - window: The portal's window.
    ///   - hostView: The portal's host view, used to skip hosted DevTools splits.
    public func noteInteractiveSplitDividerDragIfNeeded(
        _ splitView: NSSplitView,
        window: NSWindow,
        hostView: NSView
    ) {
        guard splitView.window === window else { return }
        guard !splitView.isDescendant(of: hostView) else { return }
        guard (NSEvent.pressedMouseButtons & 1) != 0 else { return }
        guard let event = NSApp.currentEvent else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - event.timestamp) < 0.1 else { return }
        guard event.window === window else { return }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            break
        default:
            return
        }
        guard splitView.arrangedSubviews.count >= 2 else { return }

        let location = splitView.convert(event.locationInWindow, from: nil)
        let first = splitView.arrangedSubviews[0].frame
        let second = splitView.arrangedSubviews[1].frame
        let thickness = splitView.dividerThickness
        let dividerRect: NSRect

        if splitView.isVertical {
            guard first.width > 1, second.width > 1 else { return }
            dividerRect = NSRect(
                x: max(0, first.maxX),
                y: 0,
                width: thickness,
                height: splitView.bounds.height
            )
        } else {
            guard first.height > 1, second.height > 1 else { return }
            dividerRect = NSRect(
                x: 0,
                y: max(0, first.maxY),
                width: splitView.bounds.width,
                height: thickness
            )
        }

        let hitRect = dividerRect.insetBy(dx: -5, dy: -5)
        if Self.dividerHitRectContains(location, rect: hitRect) {
            window.browserPortalHasInteractiveSplitDividerDrag = true
        }
    }

    /// Returns whether the window is currently in an interactive app-layout
    /// divider drag, consulting the per-window latch first and falling back to a
    /// fresh check of the current left-button mouse event.
    /// - Parameter window: The portal's window.
    /// - Returns: `true` while a left-button divider drag is in progress.
    public func isInteractiveSplitDividerDrag(in window: NSWindow) -> Bool {
        if window.browserPortalHasInteractiveSplitDividerDrag {
            return true
        }
        guard (NSEvent.pressedMouseButtons & 1) != 0 else { return false }
        guard let event = NSApp.currentEvent else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - event.timestamp) < 0.1 else { return false }
        guard event.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            return true
        default:
            return false
        }
    }

    private static func dividerHitRectContains(_ point: NSPoint, rect: NSRect) -> Bool {
        point.x >= rect.minX &&
            point.x <= rect.maxX &&
            point.y >= rect.minY &&
            point.y <= rect.maxY
    }
}
