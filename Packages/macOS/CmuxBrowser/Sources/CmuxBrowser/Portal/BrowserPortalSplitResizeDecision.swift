public import AppKit

/// Decides how the browser window portal should react to an `NSSplitView`
/// subview-resize, distinguishing app split-divider drags (which the portal
/// already tracks via its host anchors) from genuine external geometry changes.
///
/// Constructed per notification with the resizing `splitView`, the portal's
/// `window`, and the portal `hostView` (typed as `NSView`, used only via
/// `isDescendant(of:)`). Two responsibilities:
///
/// - ``noteInteractiveSplitDividerDragIfNeeded()`` runs on
///   `NSSplitView.willResizeSubviewsNotification`: if the current event is a
///   left mouse-down/drag landing on the resizing split's divider hit-rect, it
///   latches `window.browserPortalHasInteractiveSplitDividerDrag`.
/// - ``treatsSplitResizeAsExternalGeometry`` runs on
///   `NSSplitView.didResizeSubviewsNotification`: it returns `true` only when the
///   resize is not hosted web content and not part of an interactive divider
///   drag, gating the portal-wide external-geometry synchronize.
///
/// WebKit's attached DevTools uses internal `NSSplitView`s for its inspector
/// layout; those resizes descend from `hostView` and stay local to hosted
/// content, so they never trigger a portal re-sync.
public struct BrowserPortalSplitResizeDecision {
    private let splitView: NSSplitView
    private let window: NSWindow
    private let hostView: NSView

    /// Create a decision for one split-resize notification.
    ///
    /// - Parameters:
    ///   - splitView: the split view that is resizing its subviews.
    ///   - window: the portal's window; the resize is only relevant when the
    ///     split view lives in this window.
    ///   - hostView: the portal host view; a split that descends from it belongs
    ///     to hosted web content. Typed as `NSView` because it is only consulted
    ///     through `isDescendant(of:)`.
    public init(splitView: NSSplitView, window: NSWindow, hostView: NSView) {
        self.splitView = splitView
        self.window = window
        self.hostView = hostView
    }

    /// Whether this split-resize should be treated as an external geometry
    /// change that warrants a portal-wide synchronize.
    ///
    /// Returns `false` for splits not in `window`, for WebKit inspector/internal
    /// splits that descend from `hostView`, and for resizes that are part of an
    /// interactive divider drag (whose host anchors already emit coalesced
    /// geometry callbacks; running the portal sync on the same drag frame doubles
    /// WebKit refresh work and shows as visible flicker).
    @MainActor
    public var treatsSplitResizeAsExternalGeometry: Bool {
        guard splitView.window === window else { return false }
        // WebKit's attached DevTools uses internal NSSplitView instances for the
        // side/bottom inspector layout. Those resizes are local to hosted content
        // and should not trigger a full portal re-sync/refresh pass.
        guard !splitView.isDescendant(of: hostView) else { return false }
        // Browser host anchors already emit coalesced geometry callbacks while the
        // user drags a split divider. Running the portal-wide external-geometry
        // sync on the same drag frame doubles up WebKit refresh work and shows up
        // as visible flicker in browser panes.
        return !isInteractiveSplitDividerDrag
    }

    /// Latch `window.browserPortalHasInteractiveSplitDividerDrag` when the
    /// current event is a left mouse-down/drag landing on this split's divider
    /// hit-rect, so a subsequent resize is recognized as part of the drag.
    @MainActor
    public func noteInteractiveSplitDividerDragIfNeeded() {
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
        if hitRect.portalDividerHitContains(location) {
            window.browserPortalHasInteractiveSplitDividerDrag = true
        }
    }

    /// Whether the window is currently in an interactive split-divider drag,
    /// either because the willResize pass already latched the flag, or because
    /// the current event is a fresh left mouse-down/drag in this window.
    @MainActor
    private var isInteractiveSplitDividerDrag: Bool {
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
}
