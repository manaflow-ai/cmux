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
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private var trackingView: SidebarPointerTrackingView?
    @ObservationIgnored private var middleClickMonitor: Any?
    @ObservationIgnored private var menuEndObserver: NSObjectProtocol?
    @ObservationIgnored private var onMiddleClickWorkspace: ((UUID) -> Void)?

    func start(onMiddleClickWorkspace: @escaping (UUID) -> Void) {
        self.onMiddleClickWorkspace = onMiddleClickWorkspace

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
        detachTrackingView()
        rowFrames.removeAll(keepingCapacity: true)
        workspaceIdsByRowId.removeAll(keepingCapacity: true)
        lastPointerLocation = nil
    }

    func attach(to scrollView: NSScrollView?) {
        guard self.scrollView !== scrollView || trackingView?.superview !== scrollView else { return }
        detachTrackingView()
        guard let scrollView else { return }

        let trackingView = SidebarPointerTrackingView(frame: scrollView.bounds)
        trackingView.autoresizingMask = [.width, .height]
        trackingView.onPointerEvent = { [weak self] event in
            self?.recordPointerEvent(event)
        }
        trackingView.onPointerExit = { [weak self] event in
            self?.recordPointerExit(event)
        }
        scrollView.addSubview(trackingView, positioned: .above, relativeTo: nil)
        self.scrollView = scrollView
        self.trackingView = trackingView
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

    private func detachTrackingView() {
        trackingView?.onPointerEvent = nil
        trackingView?.onPointerExit = nil
        trackingView?.removeFromSuperview()
        trackingView = nil
        scrollView = nil
    }

    private func recordPointerEvent(_ event: NSEvent) {
        guard let point = swiftUIPoint(for: event) else { return }
        recordPointerLocation(point)
    }

    private func recordPointerExit(_ event: NSEvent) {
        if let point = swiftUIPoint(for: event) {
            lastPointerLocation = point
        }
        setHoveredRowId(nil)
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

    private func swiftUIPoint(for event: NSEvent) -> CGPoint? {
        // This callback is reachable only from the tracking view installed on
        // this scroll view, so its event is already scoped to the host. Do not
        // require `event.window`: synthetic headless events used by the scale
        // harness may not resolve that convenience property.
        guard let scrollView else { return nil }
        let appKitPoint = scrollView.convert(event.locationInWindow, from: nil)
        return Self.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            viewportBounds: scrollView.bounds
        )
    }

    private func reconcileHoveredRow() {
        setHoveredRowId(lastPointerLocation.flatMap { rowId(at: $0) })
    }

    private func setHoveredRowId(_ rowId: SidebarWorkspaceRenderItemID?) {
        guard hoveredRowId != rowId else { return }
        hoveredRowId = rowId
    }
}
