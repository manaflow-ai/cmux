import AppKit
import Observation

/// Owns pointer-derived interaction data for every row in one workspace sidebar.
@MainActor
@Observable
final class SidebarPointerInteractionMonitor {
    nonisolated static let coordinateSpaceName = "cmux.sidebar.workspace-pointer"

    private(set) var hoveredRowId: SidebarWorkspaceRenderItemID?

    // Geometry churn is data input, not SwiftUI render state. Keeping both
    // registries ignored is load-bearing: publishing every row frame would
    // invalidate the container and recreate the sidebar livelock at its root.
    @ObservationIgnored private var rowFrames: [SidebarWorkspaceRenderItemID: CGRect] = [:]
    @ObservationIgnored private var workspaceIdsByRowId: [SidebarWorkspaceRenderItemID: UUID] = [:]
    @ObservationIgnored private var lastPointerLocation: CGPoint?
    @ObservationIgnored private weak var resolvedScrollView: NSScrollView?
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private weak var mouseMovedWindow: NSWindow?
    @ObservationIgnored private var pointerEventMonitor: Any?
    @ObservationIgnored private var middleClickMonitor: Any?
    @ObservationIgnored private var menuEndObserver: NSObjectProtocol?
    @ObservationIgnored private var onMiddleClickWorkspace: ((UUID) -> Void)?

    func start(onMiddleClickWorkspace: @escaping (UUID) -> Void) {
        self.onMiddleClickWorkspace = onMiddleClickWorkspace

        if pointerEventMonitor == nil {
            pointerEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .mouseEntered, .mouseExited]
            ) { [weak self] event in
                self?.handlePointerEvent(event)
                return event
            }
        }
        activateResolvedScrollView()

        if middleClickMonitor == nil {
            middleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                self?.handleMiddleClick(event) ?? event
            }
        }
        if menuEndObserver == nil {
            menuEndObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let shouldReconcile = Self.shouldReconcileMenuEnd(object: notification.object)
                guard shouldReconcile else { return }
                Task { @MainActor [weak self] in
                    self?.reconcilePointerFromHostWindow()
                }
            }
        }
    }

    func stop() {
        if let middleClickMonitor {
            NSEvent.removeMonitor(middleClickMonitor)
            self.middleClickMonitor = nil
        }
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
            self.menuEndObserver = nil
        }
        onMiddleClickWorkspace = nil
        if let pointerEventMonitor {
            NSEvent.removeMonitor(pointerEventMonitor)
            self.pointerEventMonitor = nil
        }
        deactivateResolvedScrollView()
        lastPointerLocation = nil
        setHoveredRowId(nil)
    }

    func attach(to scrollView: NSScrollView?) {
        resolvedScrollView = scrollView
        activateResolvedScrollView()
    }

    private func activateResolvedScrollView() {
        guard pointerEventMonitor != nil, let resolvedScrollView else {
            deactivateResolvedScrollView()
            return
        }
        scrollView = resolvedScrollView

        let nextWindow = resolvedScrollView.window
        guard mouseMovedWindow !== nextWindow else { return }
        if let mouseMovedWindow {
            WindowMouseMovedEventsCoordinator.disable(for: mouseMovedWindow, owner: self)
        }
        mouseMovedWindow = nextWindow
        if let nextWindow {
            WindowMouseMovedEventsCoordinator.enable(for: nextWindow, owner: self)
        }
    }

    private func deactivateResolvedScrollView() {
        if let mouseMovedWindow {
            WindowMouseMovedEventsCoordinator.disable(for: mouseMovedWindow, owner: self)
        } else {
            WindowMouseMovedEventsCoordinator.disableOwner(self)
        }
        mouseMovedWindow = nil
        scrollView = nil
    }

    func updateFrame(
        _ frame: CGRect,
        for rowId: SidebarWorkspaceRenderItemID,
        workspaceId: UUID
    ) {
        rowFrames[rowId] = frame
        workspaceIdsByRowId[rowId] = workspaceId
        reconcileHoveredRow()
    }

    func removeFrame(for rowId: SidebarWorkspaceRenderItemID) {
        rowFrames.removeValue(forKey: rowId)
        workspaceIdsByRowId.removeValue(forKey: rowId)
        reconcileHoveredRow()
    }

    /// Test seam and event-input primitive in the monitor's SwiftUI coordinate space.
    func recordPointerLocation(_ point: CGPoint) {
        lastPointerLocation = point
        reconcileHoveredRow()
    }

    func rowId(at point: CGPoint) -> SidebarWorkspaceRenderItemID? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    func middleClickWorkspaceId(at point: CGPoint) -> UUID? {
        rowId(at: point).flatMap { workspaceIdsByRowId[$0] }
    }

    nonisolated static func swiftUIPoint(
        fromAppKitPoint point: CGPoint,
        viewportBounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: point.x - viewportBounds.minX,
            y: viewportBounds.maxY - point.y
        )
    }

    nonisolated static func shouldReconcileMenuEnd(object: Any?) -> Bool {
        guard let menu = object as? NSMenu else { return false }
        return menu.supermenu == nil
    }

    private func handlePointerEvent(_ event: NSEvent) {
        guard let scrollView,
              let window = scrollView.window,
              event.windowNumber == window.windowNumber else { return }
        let appKitPoint = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(appKitPoint) else {
            lastPointerLocation = nil
            setHoveredRowId(nil)
            return
        }
        recordPointerLocation(Self.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            viewportBounds: scrollView.bounds
        ))
    }

    private func reconcilePointerFromHostWindow() {
        guard let scrollView, let window = scrollView.window else {
            setHoveredRowId(nil)
            return
        }
        let appKitPoint = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        recordPointerLocation(Self.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            viewportBounds: scrollView.bounds
        ))
    }

    private func handleMiddleClick(_ event: NSEvent) -> NSEvent? {
        guard event.buttonNumber == 2,
              let scrollView,
              event.window === scrollView.window else {
            return event
        }
        let appKitPoint = scrollView.convert(event.locationInWindow, from: nil)
        let point = Self.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            viewportBounds: scrollView.bounds
        )
        guard let workspaceId = middleClickWorkspaceId(at: point) else { return event }
        recordPointerLocation(point)
        onMiddleClickWorkspace?(workspaceId)
        return nil
    }

    private func reconcileHoveredRow() {
        setHoveredRowId(lastPointerLocation.flatMap { rowId(at: $0) })
    }

    private func setHoveredRowId(_ rowId: SidebarWorkspaceRenderItemID?) {
        guard hoveredRowId != rowId else { return }
        hoveredRowId = rowId
    }
}
