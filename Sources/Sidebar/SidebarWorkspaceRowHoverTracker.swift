import AppKit
import SwiftUI

struct SidebarWorkspaceRowHoverTracker: NSViewRepresentable {
    @Binding var rowInteractionState: SidebarWorkspaceRowInteractionState

    func makeCoordinator() -> Coordinator {
        Coordinator(rowInteractionState: $rowInteractionState)
    }

    func makeNSView(context: Context) -> SidebarWorkspaceRowHoverTrackingView {
        let view = SidebarWorkspaceRowHoverTrackingView()
        let coordinator = context.coordinator
        view.onPointerHoverChanged = { hovering in
            coordinator.pointerHoverChanged(hovering)
        }
        view.onMenuTrackingChanged = { tracking in
            coordinator.menuTrackingChanged(tracking)
        }
        return view
    }

    func updateNSView(_ nsView: SidebarWorkspaceRowHoverTrackingView, context: Context) {
        context.coordinator.rowInteractionState = $rowInteractionState
    }

    final class Coordinator {
        var rowInteractionState: Binding<SidebarWorkspaceRowInteractionState>

        init(rowInteractionState: Binding<SidebarWorkspaceRowInteractionState>) {
            self.rowInteractionState = rowInteractionState
        }

        func pointerHoverChanged(_ hovering: Bool) {
            rowInteractionState.wrappedValue.setPointerHovering(hovering)
        }

        func menuTrackingChanged(_ tracking: Bool) {
            if tracking {
                rowInteractionState.wrappedValue.contextMenuTrackingDidBegin()
            } else {
                rowInteractionState.wrappedValue.contextMenuTrackingDidEnd()
            }
        }
    }
}

enum SidebarWorkspaceRowMenuTrackingScope {
    static func shouldSuppressCloseButton(
        pointerInsideRow: Bool,
        eventType: NSEvent.EventType?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard pointerInsideRow else { return false }

        switch eventType {
        case .some(.rightMouseDown), .some(.rightMouseUp):
            return true
        case .some(.leftMouseDown), .some(.leftMouseUp):
            return modifierFlags.contains(.control)
        default:
            return false
        }
    }
}

final class SidebarWorkspaceRowHoverTrackingView: NSView {
    var onPointerHoverChanged: ((Bool) -> Void)?
    var onMenuTrackingChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?
    private var lastReportedHover: Bool?
    private var isMenuTracking = false

    override func updateTrackingAreas() {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshMenuTrackingObservers()
        reconcileCurrentPointerLocation()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func mouseEntered(with event: NSEvent) {
        reconcileCurrentPointerLocation()
    }

    override func mouseExited(with event: NSEvent) {
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
                guard let self else { return }
                guard shouldSuppressHoverForMenuTracking() else { return }
                isMenuTracking = true
                onMenuTrackingChanged?(true)
                reportPointerHovering(false)
            }
        }
        if menuEndObserver == nil {
            menuEndObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                guard isMenuTracking else { return }
                isMenuTracking = false
                onMenuTrackingChanged?(false)
                reconcileCurrentPointerLocation()
            }
        }
    }

    private func shouldSuppressHoverForMenuTracking() -> Bool {
        let event = NSApp.currentEvent
        return SidebarWorkspaceRowMenuTrackingScope.shouldSuppressCloseButton(
            pointerInsideRow: isPointerInsideBounds(),
            eventType: event?.type,
            modifierFlags: event?.modifierFlags ?? []
        )
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
