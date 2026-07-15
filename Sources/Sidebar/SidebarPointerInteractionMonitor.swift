import AppKit
import Observation
import SwiftUI

/// A SwiftUI-owned AppKit view spanning the workspace-list viewport.
///
/// The host gives the pointer owner a stable window and coordinate source
/// without discovering or mutating SwiftUI's private scroll-view hierarchy.
@MainActor
struct SidebarPointerEventHost: NSViewRepresentable {
    let onResolve: @MainActor (NSView) -> Void

    func makeNSView(context: Context) -> SidebarPointerEventHostView {
        let view = SidebarPointerEventHostView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: SidebarPointerEventHostView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolve()
    }

    static func dismantleNSView(_ nsView: SidebarPointerEventHostView, coordinator: ()) {
        nsView.onResolve?(nsView)
        nsView.onResolve = nil
    }
}

@MainActor
final class SidebarPointerEventHostView: NSView {
    var onResolve: (@MainActor (NSView) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolve()
    }

    func resolve() {
        onResolve?(self)
    }
}

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
    @ObservationIgnored private weak var resolvedHostView: NSView?
    @ObservationIgnored private weak var hostView: NSView?
    @ObservationIgnored private weak var mouseMovedWindow: NSWindow?
    @ObservationIgnored private var pointerEventMonitor: Any?
    @ObservationIgnored private var middleClickMonitor: Any?
    @ObservationIgnored private var menuEndObserver: NSObjectProtocol?
    @ObservationIgnored private var onMiddleClickWorkspace: ((UUID) -> Void)?
    @ObservationIgnored private var geometryReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var geometryReconciliationGeneration: UInt = 0

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
        activateResolvedHost()

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
        geometryReconciliationGeneration &+= 1
        geometryReconciliationTask?.cancel()
        geometryReconciliationTask = nil
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
        deactivateResolvedHost()
        lastPointerLocation = nil
        setHoveredRowId(nil)
    }

    func attach(to candidate: NSView) {
        if candidate.window != nil {
            resolvedHostView = candidate
        } else if resolvedHostView === candidate {
            // Ignore teardown from an older host after SwiftUI has already
            // mounted and resolved its replacement.
            resolvedHostView = nil
        }
        activateResolvedHost()
    }

    private func activateResolvedHost() {
        guard pointerEventMonitor != nil, let resolvedHostView else {
            deactivateResolvedHost()
            return
        }
        hostView = resolvedHostView

        let nextWindow = resolvedHostView.window
        guard mouseMovedWindow !== nextWindow else { return }
        if let mouseMovedWindow {
            WindowMouseMovedEventsCoordinator.disable(for: mouseMovedWindow, owner: self)
        }
        mouseMovedWindow = nextWindow
        if let nextWindow {
            WindowMouseMovedEventsCoordinator.enable(for: nextWindow, owner: self)
        }
    }

    private func deactivateResolvedHost() {
        if let mouseMovedWindow {
            WindowMouseMovedEventsCoordinator.disable(for: mouseMovedWindow, owner: self)
        } else {
            WindowMouseMovedEventsCoordinator.disableOwner(self)
        }
        mouseMovedWindow = nil
        hostView = nil
    }

    func updateFrame(
        _ frame: CGRect,
        for rowId: SidebarWorkspaceRenderItemID,
        workspaceId: UUID
    ) {
        rowFrames[rowId] = frame
        workspaceIdsByRowId[rowId] = workspaceId
        scheduleGeometryReconciliation()
    }

    func removeFrame(for rowId: SidebarWorkspaceRenderItemID) {
        rowFrames.removeValue(forKey: rowId)
        workspaceIdsByRowId.removeValue(forKey: rowId)
        scheduleGeometryReconciliation()
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
        guard let rowId = rowId(at: point),
              let workspaceId = workspaceIdsByRowId[rowId],
              rowId == .workspace(workspaceId) else { return nil }
        return workspaceId
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
        guard let hostView,
              let window = hostView.window,
              event.windowNumber == window.windowNumber else { return }
        let appKitPoint = hostView.convert(event.locationInWindow, from: nil)
        guard hostView.bounds.contains(appKitPoint) else {
            lastPointerLocation = nil
            setHoveredRowId(nil)
            return
        }
        recordPointerLocation(Self.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            viewportBounds: hostView.bounds
        ))
    }

    private func reconcilePointerFromHostWindow() {
        guard let hostView, let window = hostView.window else {
            setHoveredRowId(nil)
            return
        }
        let appKitPoint = hostView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        recordPointerLocation(Self.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            viewportBounds: hostView.bounds
        ))
    }

    private func handleMiddleClick(_ event: NSEvent) -> NSEvent? {
        guard event.buttonNumber == 2,
              let hostView,
              let window = hostView.window,
              event.windowNumber == window.windowNumber else {
            return event
        }
        let appKitPoint = hostView.convert(event.locationInWindow, from: nil)
        let point = Self.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            viewportBounds: hostView.bounds
        )
        guard let workspaceId = middleClickWorkspaceId(at: point) else { return event }
        recordPointerLocation(point)
        onMiddleClickWorkspace?(workspaceId)
        return nil
    }

    private func reconcileHoveredRow() {
        setHoveredRowId(lastPointerLocation.flatMap { rowId(at: $0) })
    }

    private func scheduleGeometryReconciliation() {
        guard geometryReconciliationTask == nil else { return }
        geometryReconciliationGeneration &+= 1
        let generation = geometryReconciliationGeneration
        // Cross the current MainActor job boundary so onGeometryChange never
        // publishes observable state inside SwiftUI's layout transaction.
        geometryReconciliationTask = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  geometryReconciliationGeneration == generation else { return }
            geometryReconciliationTask = nil
            reconcileHoveredRow()
        }
    }

    private func setHoveredRowId(_ rowId: SidebarWorkspaceRenderItemID?) {
        guard hoveredRowId != rowId else { return }
        hoveredRowId = rowId
    }
}
