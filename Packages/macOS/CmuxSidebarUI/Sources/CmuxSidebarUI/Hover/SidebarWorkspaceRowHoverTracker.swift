import AppKit
public import SwiftUI

/// A non-hit-testing overlay that reports pointer hover and context-menu
/// tracking for a sidebar workspace row through closures.
///
/// The row owns its own interaction state (an app-side value the row mutates
/// from these callbacks); this view never reads or holds that state. It only
/// emits events, keeping it compliant with the snapshot-boundary rule for views
/// under a `LazyVStack` (no `@Observable`/`@Binding`-to-store reference below
/// the list boundary). Hover enters/exits arrive on ``onPointerHoverChanged``;
/// AppKit menu-tracking begin/end for this row's own pointer-driven context menu
/// arrives on ``onMenuTrackingChanged``.
public struct SidebarWorkspaceRowHoverTracker: NSViewRepresentable {
    private let onPointerHoverChanged: (Bool) -> Void
    private let onMenuTrackingChanged: (Bool) -> Void

    /// Creates a hover/menu-tracking reporter for a sidebar row.
    /// - Parameters:
    ///   - onPointerHoverChanged: Called with `true` on pointer enter and
    ///     `false` on pointer exit (deduplicated against the last reported value).
    ///   - onMenuTrackingChanged: Called with `true` when this row's own
    ///     pointer-driven context menu begins tracking and `false` when it ends.
    public init(
        onPointerHoverChanged: @escaping (Bool) -> Void,
        onMenuTrackingChanged: @escaping (Bool) -> Void
    ) {
        self.onPointerHoverChanged = onPointerHoverChanged
        self.onMenuTrackingChanged = onMenuTrackingChanged
    }

    public func makeNSView(context: Context) -> SidebarWorkspaceRowHoverTrackingView {
        let view = SidebarWorkspaceRowHoverTrackingView()
        view.onPointerHoverChanged = onPointerHoverChanged
        view.onMenuTrackingChanged = onMenuTrackingChanged
        return view
    }

    public func updateNSView(_ nsView: SidebarWorkspaceRowHoverTrackingView, context: Context) {
        nsView.onPointerHoverChanged = onPointerHoverChanged
        nsView.onMenuTrackingChanged = onMenuTrackingChanged
    }
}

/// Backing `NSView` for ``SidebarWorkspaceRowHoverTracker``.
///
/// Tracks pointer enter/exit over the row's visible rect and observes AppKit
/// menu begin/end notifications. A right-click (or Control + left-click) inside
/// the row opens that row's context menu; while such a menu tracks, the view
/// suppresses hover so the close button behind the menu stays hidden, then
/// reconciles the real pointer position once tracking ends.
public final class SidebarWorkspaceRowHoverTrackingView: NSView {
    /// Called with the latest deduplicated pointer-hover state.
    public var onPointerHoverChanged: ((Bool) -> Void)?
    /// Called when this row's pointer-driven context-menu tracking begins/ends.
    public var onMenuTrackingChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    // NotificationCenter observer tokens are non-Sendable; they are touched only
    // on the main actor here and in the nonisolated deinit (which has exclusive
    // access), so `nonisolated(unsafe)` is the faithful escape hatch.
    private nonisolated(unsafe) var menuBeginObserver: NSObjectProtocol?
    private nonisolated(unsafe) var menuEndObserver: NSObjectProtocol?
    private var lastReportedHover: Bool?
    private var isMenuTracking = false

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
        reconcileCurrentPointerLocation()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshMenuTrackingObservers()
        reconcileCurrentPointerLocation()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    public override func mouseEntered(with event: NSEvent) {
        reconcileCurrentPointerLocation()
    }

    public override func mouseExited(with event: NSEvent) {
        reportPointerHovering(false)
    }

    deinit {
        if let menuBeginObserver {
            NotificationCenter.default.removeObserver(menuBeginObserver)
        }
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
        }
    }

    private func refreshMenuTrackingObservers() {
        if window == nil {
            if let menuBeginObserver {
                NotificationCenter.default.removeObserver(menuBeginObserver)
                self.menuBeginObserver = nil
            }
            if let menuEndObserver {
                NotificationCenter.default.removeObserver(menuEndObserver)
                self.menuEndObserver = nil
            }
            isMenuTracking = false
            return
        }
        if menuBeginObserver == nil {
            menuBeginObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // The observer is registered with `queue: .main`, so the block is
                // genuinely delivered on the main thread; assumeIsolated reaches
                // this @MainActor view's members without a hop (no assumeIsolated
                // of a manufactured domain).
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.shouldSuppressHoverForMenuTracking() else { return }
                    self.isMenuTracking = true
                    self.onMenuTrackingChanged?(true)
                    self.reportPointerHovering(false)
                }
            }
        }
        if menuEndObserver == nil {
            menuEndObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Delivered on the main thread (queue: .main); see the begin
                // observer above for the assumeIsolated justification.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.isMenuTracking else { return }
                    self.isMenuTracking = false
                    self.onMenuTrackingChanged?(false)
                    self.reconcileCurrentPointerLocation()
                }
            }
        }
    }

    private func shouldSuppressHoverForMenuTracking() -> Bool {
        let event = NSApp.currentEvent
        return SidebarRowMenuTrackingContext(
            pointerInsideRow: isPointerInsideBounds(),
            eventType: event?.type,
            modifierFlags: event?.modifierFlags ?? []
        ).suppressesCloseButton
    }

    private func reconcileCurrentPointerLocation() {
        guard !isMenuTracking else {
            reportPointerHovering(false)
            return
        }
        guard window != nil else {
            reportPointerHovering(false)
            return
        }
        reportPointerHovering(isPointerInsideBounds())
    }

    private func isPointerInsideBounds() -> Bool {
        guard let window else { return false }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInView = convert(pointInWindow, from: nil)
        return bounds.contains(pointInView)
    }

    private func reportPointerHovering(_ hovering: Bool) {
        guard lastReportedHover != hovering else { return }
        lastReportedHover = hovering
        onPointerHoverChanged?(hovering)
    }
}
