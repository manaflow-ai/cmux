import SwiftUI
import Foundation
import AppKit
import MetalKit
import CMUXLayout

private let workspaceCanvasFreeformCoordinateSpace = "WorkspaceCanvasFreeformCoordinateSpace"

@MainActor
private enum WorkspaceCanvasSurfaceMountManager {
    static func apply(
        panel: (any Panel)?,
        frameInWindow: CGRect?,
        nativeContentSize: CGSize,
        scale: CGFloat
    ) {
        let presentation = frameInWindow.map {
            CanvasSurfacePresentation(
                frameInWindow: $0,
                nativeContentSize: nativeContentSize,
                scale: scale
            )
        }

        if let terminalPanel = panel as? TerminalPanel {
            TerminalWindowPortalRegistry.updateEntryVisibility(for: terminalPanel.hostedView, visibleInUI: presentation != nil)
            TerminalWindowPortalRegistry.setCanvasSurfacePresentation(
                hostedView: terminalPanel.hostedView,
                presentation: presentation
            )
            return
        }

        if let browserPanel = panel as? BrowserPanel {
            BrowserWindowPortalRegistry.updateEntryVisibility(
                for: browserPanel.webView,
                visibleInUI: presentation != nil,
                zPriority: presentation == nil ? 0 : 10
            )
            BrowserWindowPortalRegistry.setCanvasSurfacePresentation(
                webView: browserPanel.webView,
                presentation: presentation
            )
        }
    }

    static func park(panel: (any Panel)?) {
        if let terminalPanel = panel as? TerminalPanel {
            TerminalWindowPortalRegistry.updateEntryVisibility(for: terminalPanel.hostedView, visibleInUI: false)
            TerminalWindowPortalRegistry.setCanvasSurfacePresentation(hostedView: terminalPanel.hostedView, presentation: nil)
            return
        }

        if let browserPanel = panel as? BrowserPanel {
            BrowserWindowPortalRegistry.updateEntryVisibility(for: browserPanel.webView, visibleInUI: false, zPriority: 0)
            BrowserWindowPortalRegistry.setCanvasSurfacePresentation(webView: browserPanel.webView, presentation: nil)
        }
    }

    static func currentFrameInWindow(panel: (any Panel)?) -> CGRect? {
        if let terminalPanel = panel as? TerminalPanel {
            return usableFrame(terminalPanel.hostedView.debugPortalFrameInWindow)
        }

        if let browserPanel = panel as? BrowserPanel {
            if let snapshot = BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView),
               let frame = usableFrame(snapshot.frameInWindow) {
                return frame
            }
            guard browserPanel.webView.window != nil else { return nil }
            return usableFrame(browserPanel.webView.convert(browserPanel.webView.bounds, to: nil))
        }

        return nil
    }

    static func clearTransientOverrides() {
        TerminalWindowPortalRegistry.clearInteractiveFrameOverridesForAllWindows()
        BrowserWindowPortalRegistry.clearInteractiveFrameOverridesForAllWindows()
    }

    static func synchronizeAll() {
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
        BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
    }

    private static func usableFrame(_ frame: CGRect) -> CGRect? {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.size.width.isFinite,
              frame.size.height.isFinite,
              frame.width > 1,
              frame.height > 1 else {
            return nil
        }
        return frame
    }
}

private struct CanvasMetalSceneBackdrop: NSViewRepresentable {
    var backgroundColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(backgroundColor: backgroundColor)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = context.coordinator
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.clearColor = context.coordinator.clearColor
        view.layer?.isOpaque = true
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.backgroundColor = backgroundColor
        nsView.clearColor = context.coordinator.clearColor
        nsView.setNeedsDisplay(nsView.bounds)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var backgroundColor: NSColor
        private let commandQueue: MTLCommandQueue?

        init(backgroundColor: NSColor) {
            self.backgroundColor = backgroundColor
            self.commandQueue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()
        }

        var clearColor: MTLClearColor {
            let color = backgroundColor.usingColorSpace(.deviceRGB) ?? backgroundColor
            return MTLClearColor(
                red: Double(color.redComponent),
                green: Double(color.greenComponent),
                blue: Double(color.blueComponent),
                alpha: 1
            )
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            _ = size
            view.setNeedsDisplay(view.bounds)
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

enum WorkspaceCanvasResizeHitRegionRegistry {
    struct Region {
        var itemID: LayoutItemID?
        var handle: CanvasResizeHandle?
        var frameInWindow: CGRect
        var edgeHitSize: CGFloat?
        var cornerHitSize: CGFloat?
    }

    struct Hit {
        var itemID: LayoutItemID
        var handle: CanvasResizeHandle
        var frameInWindow: CGRect
        var usesFrameMaxForLocalY: Bool
    }

    private static var regionsByWindowId: [ObjectIdentifier: [ObjectIdentifier: [Region]]] = [:]
    private static var windowIdByViewId: [ObjectIdentifier: ObjectIdentifier] = [:]
    private static var activeResizeWindowIds: Set<ObjectIdentifier> = []

    static func update(view: NSView, window: NSWindow, frameInWindow: CGRect) {
        update(view: view, window: window, framesInWindow: [frameInWindow])
    }

    static func update(view: NSView, window: NSWindow, framesInWindow: [CGRect]) {
        update(
            view: view,
            window: window,
            regions: framesInWindow.map { Region(itemID: nil, handle: nil, frameInWindow: $0) }
        )
    }

    static func update(view: NSView, window: NSWindow, regions: [Region]) {
        let usableRegions = regions.filter { region in
            region.frameInWindow.width > 1 && region.frameInWindow.height > 1
        }
        guard !usableRegions.isEmpty else {
            remove(view: view)
            return
        }

        let viewId = ObjectIdentifier(view)
        let windowId = ObjectIdentifier(window)
        if let oldWindowId = windowIdByViewId[viewId], oldWindowId != windowId {
            regionsByWindowId[oldWindowId]?.removeValue(forKey: viewId)
            if regionsByWindowId[oldWindowId]?.isEmpty == true {
                regionsByWindowId.removeValue(forKey: oldWindowId)
            }
        }

        windowIdByViewId[viewId] = windowId
        regionsByWindowId[windowId, default: [:]][viewId] = usableRegions
    }

    static func remove(view: NSView) {
        let viewId = ObjectIdentifier(view)
        guard let windowId = windowIdByViewId.removeValue(forKey: viewId) else { return }
        regionsByWindowId[windowId]?.removeValue(forKey: viewId)
        if regionsByWindowId[windowId]?.isEmpty == true {
            regionsByWindowId.removeValue(forKey: windowId)
        }
    }

    static func contains(pointInWindow point: NSPoint, in window: NSWindow) -> Bool {
        guard let regions = regionsByWindowId[ObjectIdentifier(window)] else { return false }
        return regions.values.contains { viewRegions in
            viewRegions.contains { $0.frameInWindow.insetBy(dx: -2, dy: -2).contains(point) }
        }
    }

    static func hit(pointInWindow point: NSPoint, in window: NSWindow) -> Hit? {
        guard let regions = regionsByWindowId[ObjectIdentifier(window)] else { return nil }
        for viewRegions in regions.values {
            for region in viewRegions where region.frameInWindow.insetBy(dx: -2, dy: -2).contains(point) {
                guard let itemID = region.itemID else {
                    continue
                }
                if let handle = region.handle {
                    return Hit(
                        itemID: itemID,
                        handle: handle,
                        frameInWindow: region.frameInWindow.standardized,
                        usesFrameMaxForLocalY: true
                    )
                }
                let frame = region.frameInWindow.standardized
                let hitArea = CanvasResizeHitArea(
                    cardSize: frame.size,
                    edgeHitSize: region.edgeHitSize ?? 16,
                    cornerHitSize: region.cornerHitSize ?? 44
                )
                let localPointFromTop = CGPoint(
                    x: point.x - frame.minX,
                    y: frame.maxY - point.y
                )
                let localPointFromBottom = CGPoint(
                    x: point.x - frame.minX,
                    y: point.y - frame.minY
                )
                let topHandle = hitArea.handle(at: localPointFromTop)
                let bottomHandle = hitArea.handle(at: localPointFromBottom)
                guard let preferred = preferredHandle(topHandle, bottomHandle) else {
                    continue
                }
                return Hit(
                    itemID: itemID,
                    handle: preferred.handle,
                    frameInWindow: frame,
                    usesFrameMaxForLocalY: preferred.usesFrameMaxForLocalY
                )
            }
        }
        return nil
    }

    private static func preferredHandle(
        _ first: CanvasResizeHandle?,
        _ second: CanvasResizeHandle?
    ) -> (handle: CanvasResizeHandle, usesFrameMaxForLocalY: Bool)? {
        if let first, first.isCorner {
            return (first, true)
        }
        if let second, second.isCorner {
            return (second, false)
        }
        if let first {
            return (first, true)
        }
        if let second {
            return (second, false)
        }
        return nil
    }

    static func beginPointerResize(in window: NSWindow) {
        activeResizeWindowIds.insert(ObjectIdentifier(window))
    }

    static func endPointerResize(in window: NSWindow) {
        activeResizeWindowIds.remove(ObjectIdentifier(window))
    }

    static func isPointerResizeActive(in window: NSWindow) -> Bool {
        activeResizeWindowIds.contains(ObjectIdentifier(window))
    }
}

enum WorkspaceCanvasDragHitRegionRegistry {
    struct Region {
        var itemID: LayoutItemID
        var frameInWindow: CGRect
    }

    private static var regionsByWindowId: [ObjectIdentifier: [ObjectIdentifier: Region]] = [:]
    private static var windowIdByViewId: [ObjectIdentifier: ObjectIdentifier] = [:]
    private static var activeDragWindowIds: Set<ObjectIdentifier> = []

    static func update(view: NSView, window: NSWindow, itemID: LayoutItemID, frameInWindow: CGRect) {
        guard frameInWindow.width > 1, frameInWindow.height > 1 else {
            remove(view: view)
            return
        }

        let viewId = ObjectIdentifier(view)
        let windowId = ObjectIdentifier(window)
        if let oldWindowId = windowIdByViewId[viewId], oldWindowId != windowId {
            regionsByWindowId[oldWindowId]?.removeValue(forKey: viewId)
            if regionsByWindowId[oldWindowId]?.isEmpty == true {
                regionsByWindowId.removeValue(forKey: oldWindowId)
            }
        }

        windowIdByViewId[viewId] = windowId
        regionsByWindowId[windowId, default: [:]][viewId] = Region(
            itemID: itemID,
            frameInWindow: frameInWindow
        )
    }

    static func remove(view: NSView) {
        let viewId = ObjectIdentifier(view)
        guard let windowId = windowIdByViewId.removeValue(forKey: viewId) else { return }
        regionsByWindowId[windowId]?.removeValue(forKey: viewId)
        if regionsByWindowId[windowId]?.isEmpty == true {
            regionsByWindowId.removeValue(forKey: windowId)
        }
    }

    static func hit(pointInWindow point: NSPoint, in window: NSWindow) -> LayoutItemID? {
        guard let regions = regionsByWindowId[ObjectIdentifier(window)] else { return nil }
        for region in regions.values where region.frameInWindow.insetBy(dx: -3, dy: -3).contains(point) {
            return region.itemID
        }
        return nil
    }

    static func beginPointerDrag(in window: NSWindow) {
        activeDragWindowIds.insert(ObjectIdentifier(window))
    }

    static func endPointerDrag(in window: NSWindow) {
        activeDragWindowIds.remove(ObjectIdentifier(window))
    }

    static func isPointerDragActive(in window: NSWindow) -> Bool {
        activeDragWindowIds.contains(ObjectIdentifier(window))
    }
}

private extension CanvasResizeHandle {
    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return true
        case .top, .bottom, .left, .right:
            return false
        }
    }
}

private struct CanvasDragRegistrationLayer: NSViewRepresentable {
    var itemID: LayoutItemID

    func makeNSView(context: Context) -> CanvasDragRegistrationView {
        let view = CanvasDragRegistrationView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: CanvasDragRegistrationView, context: Context) {
        nsView.itemID = itemID
        nsView.updateRegistration()
    }

    static func dismantleNSView(_ nsView: CanvasDragRegistrationView, coordinator: ()) {
        WorkspaceCanvasDragHitRegionRegistry.remove(view: nsView)
    }
}

private final class CanvasDragRegistrationView: NSView {
    var itemID: LayoutItemID?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRegistration()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        updateRegistration()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRegistration()
    }

    override func layout() {
        super.layout()
        updateRegistration()
    }

    func updateRegistration() {
        guard let window, let itemID else {
            WorkspaceCanvasDragHitRegionRegistry.remove(view: self)
            return
        }
        WorkspaceCanvasDragHitRegionRegistry.update(
            view: self,
            window: window,
            itemID: itemID,
            frameInWindow: convert(bounds, to: nil)
        )
    }

    deinit {
        WorkspaceCanvasDragHitRegionRegistry.remove(view: self)
    }
}

private struct CanvasDragEventMonitorLayer: NSViewRepresentable {
    var onDragChanged: (LayoutItemID, CGSize) -> Void
    var onDragEnded: (LayoutItemID) -> Void
    var onClick: (LayoutItemID) -> Void

    func makeNSView(context: Context) -> CanvasDragEventMonitorView {
        let view = CanvasDragEventMonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: CanvasDragEventMonitorView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.onClick = onClick
        nsView.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: CanvasDragEventMonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

private final class CanvasDragEventMonitorView: NSView {
    var onDragChanged: ((LayoutItemID, CGSize) -> Void)?
    var onDragEnded: ((LayoutItemID) -> Void)?
    var onClick: ((LayoutItemID) -> Void)?

    private struct PendingDrag {
        var itemID: LayoutItemID
        var startPointInWindow: NSPoint
    }

    private var monitor: Any?
    private var pendingDrag: PendingDrag?
    private var activeDrag: PendingDrag?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitorIfNeeded()
        }
    }

    func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let window, activeDrag != nil {
            WorkspaceCanvasDragHitRegionRegistry.endPointerDrag(in: window)
        }
        monitor = nil
        pendingDrag = nil
        activeDrag = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window,
              event.window === window else {
            return event
        }

        switch event.type {
        case .leftMouseDown:
            pendingDrag = nil
            activeDrag = nil
            guard !WorkspaceCanvasResizeHitRegionRegistry.isPointerResizeActive(in: window),
                  WorkspaceCanvasResizeHitRegionRegistry.hit(pointInWindow: event.locationInWindow, in: window) == nil,
                  let itemID = WorkspaceCanvasDragHitRegionRegistry.hit(
                      pointInWindow: event.locationInWindow,
                      in: window
                  ) else {
                return event
            }
            pendingDrag = PendingDrag(itemID: itemID, startPointInWindow: event.locationInWindow)
            return event
        case .leftMouseDragged:
            guard let drag = activeDrag ?? pendingDrag else { return event }
            let translation = CGSize(
                width: event.locationInWindow.x - drag.startPointInWindow.x,
                height: drag.startPointInWindow.y - event.locationInWindow.y
            )
            if activeDrag == nil {
                guard abs(translation.width) >= 1 || abs(translation.height) >= 1 else {
                    return event
                }
                activeDrag = drag
                WorkspaceCanvasDragHitRegionRegistry.beginPointerDrag(in: window)
            }
            onDragChanged?(drag.itemID, translation)
            return nil
        case .leftMouseUp:
            defer {
                pendingDrag = nil
                activeDrag = nil
            }
            guard let activeDrag else {
                if let pendingDrag {
                    onClick?(pendingDrag.itemID)
                    return nil
                }
                return event
            }
            onDragEnded?(activeDrag.itemID)
            WorkspaceCanvasDragHitRegionRegistry.endPointerDrag(in: window)
            return nil
        default:
            return event
        }
    }

    deinit {
        removeMonitor()
    }
}

private struct CanvasPanEventMonitorLayer: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onZoom: (Double, CGPoint) -> Void
    var onMagnify: (Double, CGPoint) -> Void
    var onSmartZoom: (CGPoint) -> Void

    func makeNSView(context: Context) -> CanvasPanEventMonitorView {
        let view = CanvasPanEventMonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: CanvasPanEventMonitorView, context: Context) {
        nsView.onPan = onPan
        nsView.onZoom = onZoom
        nsView.onMagnify = onMagnify
        nsView.onSmartZoom = onSmartZoom
        nsView.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: CanvasPanEventMonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

private final class CanvasPanEventMonitorView: NSView {
    var onPan: ((CGSize) -> Void)?
    var onZoom: ((Double, CGPoint) -> Void)?
    var onMagnify: ((Double, CGPoint) -> Void)?
    var onSmartZoom: ((CGPoint) -> Void)?

    private var monitor: Any?
    private var wheelGestureState = CanvasWheelGestureState()
    private var activeMiddlePanPointInWindow: NSPoint?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitorIfNeeded()
        }
    }

    func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify, .smartMagnify, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        activeMiddlePanPointInWindow = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window,
              event.window === window,
              !WorkspaceCanvasDragHitRegionRegistry.isPointerDragActive(in: window),
              !WorkspaceCanvasResizeHitRegionRegistry.isPointerResizeActive(in: window) else {
            return event
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        if activeMiddlePanPointInWindow == nil {
            guard bounds.contains(localPoint) else { return event }
        }

        switch event.type {
        case .otherMouseDown:
            guard event.buttonNumber == 2 else { return event }
            activeMiddlePanPointInWindow = event.locationInWindow
            return nil
        case .otherMouseDragged:
            guard event.buttonNumber == 2,
                  let previousPoint = activeMiddlePanPointInWindow else {
                return event
            }
            let currentPoint = event.locationInWindow
            activeMiddlePanPointInWindow = currentPoint
            onPan?(
                CGSize(
                    width: currentPoint.x - previousPoint.x,
                    height: previousPoint.y - currentPoint.y
                )
            )
            return nil
        case .otherMouseUp:
            guard event.buttonNumber == 2,
                  activeMiddlePanPointInWindow != nil else {
                return event
            }
            activeMiddlePanPointInWindow = nil
            return nil
        case .scrollWheel:
            let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            guard abs(delta.width) > 0.01 || abs(delta.height) > 0.01 else { return event }
            let isMomentum = event.momentumPhase != [] && event.momentumPhase != .mayBegin
            let didEndMomentum = event.momentumPhase == .ended || event.momentumPhase == .cancelled
            let isCommandWheel = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)

            switch wheelGestureState.action(
                hasCommandModifier: isCommandWheel,
                isMomentum: isMomentum,
                didEndMomentum: didEndMomentum
            ) {
            case .zoom:
                onZoom?(Double(delta.height), localPoint)
                return nil
            case .consume:
                return nil
            case .pan:
                onPan?(delta)
                return nil
            }
        case .magnify:
            guard abs(event.magnification) > 0.0001 else { return event }
            onMagnify?(Double(event.magnification), localPoint)
            return nil
        case .smartMagnify:
            onSmartZoom?(localPoint)
            return nil
        default:
            return event
        }
    }

    deinit {
        removeMonitor()
    }
}

private struct CanvasHeaderDragInteractionLayer: NSViewRepresentable {
    var onDragChanged: (CGSize) -> Void
    var onDragEnded: () -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> CanvasHeaderDragInteractionView {
        let view = CanvasHeaderDragInteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: CanvasHeaderDragInteractionView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.onClick = onClick
    }
}

private final class CanvasHeaderDragInteractionView: NSView {
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    var onClick: (() -> Void)?

    private var dragStartPoint: CGPoint?
    private var didDrag = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let translation = CGSize(
            width: point.x - dragStartPoint.x,
            height: point.y - dragStartPoint.y
        )
        if !didDrag {
            guard abs(translation.width) >= 1 || abs(translation.height) >= 1 else { return }
            didDrag = true
        }
        onDragChanged?(translation)
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnded?()
        } else {
            onClick?()
        }
        dragStartPoint = nil
        didDrag = false
    }
}

private struct CanvasResizeInteractionLayer: NSViewRepresentable {
    var itemID: LayoutItemID
    var edgeHitSize: CGFloat
    var cornerHitSize: CGFloat
    var onResizeChanged: (CanvasResizeHandle, CGSize) -> Void
    var onResizeEnded: (CanvasResizeHandle) -> Void

    func makeNSView(context: Context) -> CanvasResizeInteractionView {
        let view = CanvasResizeInteractionView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: CanvasResizeInteractionView, context: Context) {
        nsView.itemID = itemID
        nsView.edgeHitSize = edgeHitSize
        nsView.cornerHitSize = cornerHitSize
        nsView.onResizeChanged = onResizeChanged
        nsView.onResizeEnded = onResizeEnded
        nsView.updateRegistration()
    }

    static func dismantleNSView(_ nsView: CanvasResizeInteractionView, coordinator: ()) {
        WorkspaceCanvasResizeHitRegionRegistry.remove(view: nsView)
    }
}

private final class CanvasResizeInteractionView: NSView {
    var itemID: LayoutItemID?
    var edgeHitSize: CGFloat = 16
    var cornerHitSize: CGFloat = 44
    var onResizeChanged: ((CanvasResizeHandle, CGSize) -> Void)?
    var onResizeEnded: ((CanvasResizeHandle) -> Void)?

    private var activeHandle: CanvasResizeHandle?
    private var dragStartPoint: CGPoint?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        resizeHitArea.handle(at: point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = resizeHitArea.handle(at: point) else { return }
        activeHandle = handle
        dragStartPoint = point
        if let window {
            WorkspaceCanvasResizeHitRegionRegistry.beginPointerResize(in: window)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeHandle, let dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        onResizeChanged?(
            activeHandle,
            CGSize(width: point.x - dragStartPoint.x, height: point.y - dragStartPoint.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let activeHandle else { return }
        onResizeEnded?(activeHandle)
        self.activeHandle = nil
        dragStartPoint = nil
        if let window {
            WorkspaceCanvasResizeHitRegionRegistry.endPointerResize(in: window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRegistration()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        updateRegistration()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRegistration()
    }

    override func layout() {
        super.layout()
        updateRegistration()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for region in resizeHitArea.hitRegions() {
            addCursorRect(region.frame, cursor: .resizeLeftRight)
        }
    }

    func updateRegistration() {
        guard let window else {
            WorkspaceCanvasResizeHitRegionRegistry.remove(view: self)
            return
        }
        let regions = [
            WorkspaceCanvasResizeHitRegionRegistry.Region(
                itemID: itemID,
                handle: nil,
                frameInWindow: convert(bounds, to: nil),
                edgeHitSize: edgeHitSize,
                cornerHitSize: cornerHitSize
            )
        ]
        WorkspaceCanvasResizeHitRegionRegistry.update(
            view: self,
            window: window,
            regions: regions
        )
        discardCursorRects()
        resetCursorRects()
    }

    private var resizeHitArea: CanvasResizeHitArea {
        CanvasResizeHitArea(
            cardSize: bounds.size,
            edgeHitSize: edgeHitSize,
            cornerHitSize: cornerHitSize
        )
    }

    deinit {
        WorkspaceCanvasResizeHitRegionRegistry.remove(view: self)
    }
}

private struct CanvasResizeEventMonitorLayer: NSViewRepresentable {
    var onResizeChanged: (LayoutItemID, CanvasResizeHandle, CGSize) -> Void
    var onResizeEnded: (LayoutItemID, CanvasResizeHandle) -> Void

    func makeNSView(context: Context) -> CanvasResizeEventMonitorView {
        let view = CanvasResizeEventMonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: CanvasResizeEventMonitorView, context: Context) {
        nsView.onResizeChanged = onResizeChanged
        nsView.onResizeEnded = onResizeEnded
        nsView.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: CanvasResizeEventMonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }
}

private final class CanvasResizeEventMonitorView: NSView {
    var onResizeChanged: ((LayoutItemID, CanvasResizeHandle, CGSize) -> Void)?
    var onResizeEnded: ((LayoutItemID, CanvasResizeHandle) -> Void)?

    private var monitor: Any?
    private var activeResize: (
        itemID: LayoutItemID,
        handle: CanvasResizeHandle,
        startPointInWindow: NSPoint,
        frameInWindow: CGRect,
        usesFrameMaxForLocalY: Bool
    )?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitorIfNeeded()
        }
    }

    func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        activeResize = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window,
              event.window === window else {
            return event
        }

        switch event.type {
        case .leftMouseDown:
            guard let hit = WorkspaceCanvasResizeHitRegionRegistry.hit(
                pointInWindow: event.locationInWindow,
                in: window
            ) else {
                return event
            }
            activeResize = (
                hit.itemID,
                hit.handle,
                event.locationInWindow,
                hit.frameInWindow,
                hit.usesFrameMaxForLocalY
            )
            WorkspaceCanvasResizeHitRegionRegistry.beginPointerResize(in: window)
            return nil
        case .leftMouseDragged:
            guard let activeResize else { return event }
            let frame = activeResize.frameInWindow
            let startY = activeResize.usesFrameMaxForLocalY
                ? frame.maxY - activeResize.startPointInWindow.y
                : activeResize.startPointInWindow.y - frame.minY
            let currentY = activeResize.usesFrameMaxForLocalY
                ? frame.maxY - event.locationInWindow.y
                : event.locationInWindow.y - frame.minY
            let translation = CGSize(
                width: event.locationInWindow.x - activeResize.startPointInWindow.x,
                height: currentY - startY
            )
            onResizeChanged?(activeResize.itemID, activeResize.handle, translation)
            return nil
        case .leftMouseUp:
            guard let activeResize else { return event }
            onResizeEnded?(activeResize.itemID, activeResize.handle)
            self.activeResize = nil
            WorkspaceCanvasResizeHitRegionRegistry.endPointerResize(in: window)
            return nil
        default:
            return event
        }
    }

    deinit {
        removeMonitor()
    }
}

private struct CanvasPortalPresentationReporter: NSViewRepresentable {
    var onFrameInWindowChanged: (CGRect?) -> Void

    func makeNSView(context: Context) -> CanvasPortalPresentationReporterView {
        let view = CanvasPortalPresentationReporterView()
        view.onFrameInWindowChanged = onFrameInWindowChanged
        return view
    }

    func updateNSView(_ nsView: CanvasPortalPresentationReporterView, context: Context) {
        nsView.onFrameInWindowChanged = onFrameInWindowChanged
        nsView.scheduleFramePublish()
    }

    static func dismantleNSView(_ nsView: CanvasPortalPresentationReporterView, coordinator: ()) {
        nsView.onFrameInWindowChanged?(nil)
        nsView.onFrameInWindowChanged = nil
    }
}

private final class CanvasPortalPresentationReporterView: NSView {
    var onFrameInWindowChanged: ((CGRect?) -> Void)?
    private var lastPublishedFrameInWindow: CGRect?
    private var hasPendingFramePublish = false

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        scheduleFramePublish()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFramePublish()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleFramePublish()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleFramePublish()
    }

    func scheduleFramePublish() {
        guard !hasPendingFramePublish else { return }
        hasPendingFramePublish = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            hasPendingFramePublish = false
            publishFrameIfNeeded()
        }
    }

    private func publishFrameIfNeeded() {
        guard window != nil else {
            if lastPublishedFrameInWindow != nil {
                lastPublishedFrameInWindow = nil
                onFrameInWindowChanged?(nil)
            }
            return
        }

        let frameInWindow = convert(bounds, to: nil)
        guard frameInWindow.origin.x.isFinite,
              frameInWindow.origin.y.isFinite,
              frameInWindow.size.width.isFinite,
              frameInWindow.size.height.isFinite,
              frameInWindow.width > 1,
              frameInWindow.height > 1 else {
            if lastPublishedFrameInWindow != nil {
                lastPublishedFrameInWindow = nil
                onFrameInWindowChanged?(nil)
            }
            return
        }

        if let lastPublishedFrameInWindow,
           abs(lastPublishedFrameInWindow.minX - frameInWindow.minX) <= 0.5,
           abs(lastPublishedFrameInWindow.minY - frameInWindow.minY) <= 0.5,
           abs(lastPublishedFrameInWindow.width - frameInWindow.width) <= 0.5,
           abs(lastPublishedFrameInWindow.height - frameInWindow.height) <= 0.5 {
            return
        }

        lastPublishedFrameInWindow = frameInWindow
        onFrameInWindowChanged?(frameInWindow)
    }
}

enum TmuxOverlayExperimentTarget: String, CaseIterable, Codable, Sendable {
    case surface
    case workspaceLayoutPane
    case tmuxActivePane

    var usesWorkspacePaneOverlay: Bool {
        self == .workspaceLayoutPane
    }

    var usesTmuxActivePaneOverlay: Bool {
        self == .tmuxActivePane
    }
}

struct TmuxOverlayExperimentSettings {
    static let enabledKey = "tmuxOverlayExperimentEnabled"
    static let targetKey = "tmuxOverlayExperimentTarget"
    static let defaultEnabled = false
    static let defaultTarget: TmuxOverlayExperimentTarget = .surface

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func target(defaults: UserDefaults = .standard) -> TmuxOverlayExperimentTarget {
        target(
            enabled: isEnabled(defaults: defaults),
            rawValue: defaults.string(forKey: targetKey)
        )
    }

    static func target(enabled: Bool, rawValue: String?) -> TmuxOverlayExperimentTarget {
        guard enabled else { return .surface }
        guard let rawValue,
              let target = TmuxOverlayExperimentTarget(rawValue: rawValue) else {
            return defaultTarget
        }
        return target
    }
}

private enum WorkspaceTitlebarInteractionMetrics {
    // Keep in sync with the minimal-mode titlebar strip so the monitor only
    // covers titlebar chrome.
    static let minimalModeTopStripHeight: CGFloat = MinimalModeChromeMetrics.titlebarHeight
}

struct TmuxPaneLayoutPane: Codable, Equatable, Sendable {
    let paneId: String
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let isActive: Bool
}

struct TmuxPaneLayoutReport: Codable, Equatable, Sendable {
    let panes: [TmuxPaneLayoutPane]

    var activePane: TmuxPaneLayoutPane? {
        panes.first(where: \.isActive) ?? panes.first
    }
}

func tmuxActivePaneOverlayRect(
    surfaceFrame: CGRect,
    cellSize: CGSize,
    pane: TmuxPaneLayoutPane
) -> CGRect? {
    guard cellSize.width > 0,
          cellSize.height > 0,
          pane.width > 0,
          pane.height > 0 else {
        return nil
    }

    return CGRect(
        x: surfaceFrame.origin.x + (CGFloat(pane.left) * cellSize.width),
        y: surfaceFrame.origin.y + (CGFloat(pane.top) * cellSize.height),
        width: CGFloat(pane.width) * cellSize.width,
        height: CGFloat(pane.height) * cellSize.height
    )
}

private extension PixelRect {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct TmuxWorkspacePaneOverlayRenderState: Equatable {
    let workspaceId: UUID
    let unreadRects: [CGRect]
    let flashRect: CGRect?
    let flashToken: UInt64
    let flashReason: WorkspaceAttentionFlashReason?
}

@MainActor
final class TmuxWorkspacePaneOverlayModel: ObservableObject {
    @Published private(set) var unreadRects: [CGRect] = []
    @Published private(set) var flashRect: CGRect?
    @Published private(set) var flashStartedAt: Date?
    @Published private(set) var flashReason: WorkspaceAttentionFlashReason?

    private var lastWorkspaceId: UUID?
    private var lastFlashToken: UInt64?

    func apply(
        _ state: TmuxWorkspacePaneOverlayRenderState,
        now: () -> Date = Date.init
    ) {
        unreadRects = state.unreadRects
        flashRect = state.flashRect
        flashReason = state.flashReason

        let didChangeWorkspace = lastWorkspaceId != state.workspaceId
        if didChangeWorkspace {
            lastWorkspaceId = state.workspaceId
            lastFlashToken = state.flashToken
            flashStartedAt = nil
            return
        }

        if let lastFlashToken,
           state.flashToken != lastFlashToken,
           state.flashRect != nil {
            flashStartedAt = now()
        }
        self.lastFlashToken = state.flashToken
    }

    func clear() {
        unreadRects = []
        flashRect = nil
        flashStartedAt = nil
        flashReason = nil
        lastWorkspaceId = nil
        lastFlashToken = nil
    }
}

/// View that renders a Workspace's content using WorkspaceLayoutView
struct WorkspaceContentView: View {
    private struct DeferredThemeRefresh {
        let reason: String
        let backgroundOverride: NSColor?
        let backgroundEventId: UInt64?
        let backgroundSource: String?
        let notificationPayloadHex: String?
        let forceInitialApply: Bool
    }

    @ObservedObject var workspace: Workspace
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let isFullScreen: Bool
    let workspacePortalPriority: Int
    let onThemeRefreshRequest: ((
        _ reason: String,
        _ backgroundEventId: UInt64?,
        _ backgroundSource: String?,
        _ notificationPayloadHex: String?
    ) -> Void)?
    @State private var config = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "stateInit")
    @State private var lastAppliedUsesHostLayerBackground = GhosttyApp.shared.usesHostLayerBackground
    @State private var deferredThemeRefresh: DeferredThemeRefresh?
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var notificationStore: TerminalNotificationStore

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    static func panelVisibleInUI(
        isWorkspaceVisible: Bool,
        isSelectedInPane: Bool,
        isFocused: Bool
    ) -> Bool {
        _ = isFocused
        guard isWorkspaceVisible else { return false }
        return isSelectedInPane
    }

    var body: some View {
        let appearance = PanelAppearance.fromConfig(config)
        let isSplit = workspace.layoutController.allPaneIds.count > 1 ||
            workspace.panels.count > 1
        let usesWorkspacePaneOverlay = TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay
        let isCanvasOverviewActive = workspace.layoutController.isCanvasOverviewActive
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        // Inactive workspaces are kept alive in a ZStack (for state preservation) but their
        // AppKit-backed views can still intercept drags. Disable drop acceptance for them.
        let _ = { workspace.layoutController.isInteractive = isWorkspaceInputActive }()

        // Wire up file drop handling so workspaceLayout's PaneDragContainerView can forward
        // Finder file drops to the correct terminal panel.
        let _ = {
            workspace.layoutController.onFileDrop = { [weak workspace] urls, paneId in
                guard let workspace else { return false }
                // Find the focused panel in this pane and drop the files into it.
                guard let tabId = workspace.layoutController.selectedTab(inPane: paneId)?.id,
                      let panelId = workspace.panelIdFromSurfaceId(tabId),
                      let panel = workspace.panels[panelId] as? TerminalPanel else { return false }
                return panel.hostedView.handleDroppedURLs(urls)
            }
        }()

        let buildPanelContent: (SurfaceTab, PaneID, Bool) -> AnyView = { tab, paneId, rendersInCanvas in
            let _ = Self.debugPanelLookup(tab: tab, workspace: workspace)
            if let panel = workspace.panel(for: tab.id) {
                let isFocused = isWorkspaceInputActive && workspace.focusedPanelId == panel.id
                let isSelectedInPane = workspace.layoutController.selectedTab(inPane: paneId)?.id == tab.id
                let isVisibleInUI = Self.panelVisibleInUI(
                    isWorkspaceVisible: isWorkspaceVisible && (rendersInCanvas || !isCanvasOverviewActive),
                    isSelectedInPane: isSelectedInPane,
                    isFocused: isFocused
                )
                let showsNotificationRing = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panel.id
                    ),
                    hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panel.id) ||
                        workspace.restoredUnreadPanelIds.contains(panel.id),
                    isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                    isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panel.id
                )
                return AnyView(PanelContentView(
                    panel: panel,
                    workspaceId: workspace.id,
                    paneId: paneId,
                    isFocused: isFocused,
                    isSelectedInPane: isSelectedInPane,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: workspacePortalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: showsNotificationRing && !usesWorkspacePaneOverlay,
                    onFocus: {
                        // Keep workspaceLayout focus in sync with the AppKit first responder for the
                        // active workspace. This prevents divergence between the blue focused-tab
                        // indicator and where keyboard input/flash-focus actually lands.
                        guard isWorkspaceInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.focusPanel(panel.id, trigger: .terminalFirstResponder)
                    },
                    onRequestPanelFocus: {
                        guard isWorkspaceInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.layoutController.focusPane(paneId)
                        AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                            workspaceId: workspace.id,
                            panelId: panel.id,
                            in: NSApp.keyWindow ?? NSApp.mainWindow
                        )
                        workspace.focusPanel(panel.id)
                    },
                    onTriggerFlash: { workspace.triggerDebugFlash(panelId: panel.id) }
                )
                .onTapGesture {
                    workspace.layoutController.focusPane(paneId)
                }
                )
            } else {
                return AnyView(EmptyPanelView(workspace: workspace, paneId: paneId))
            }
        }

        let workspaceLayoutView = WorkspaceLayoutView(controller: workspace.layoutController) { tab, paneId in
            // Content for each tab in workspaceLayout
            buildPanelContent(tab, paneId, false)
        } emptyPane: { paneId in
            // Empty pane content
            EmptyPanelView(workspace: workspace, paneId: paneId)
                .onTapGesture {
                    workspace.layoutController.focusPane(paneId)
                }
        }
        .internalOnlyTabDrag()
        // Split zoom swaps CMUXLayout between the full split tree and a single pane view.
        // Recreate the CMUXLayout subtree on zoom enter/exit so stale pre-zoom pane chrome
        // cannot remain stacked above portal-hosted browser content.
        .id(splitZoomRenderIdentity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncCMUXLayoutNotificationBadges()
            refreshGhosttyAppearanceConfig(reason: "onAppear")
        }
        .onChange(of: isWorkspaceVisible) { _, isVisible in
            guard isVisible else { return }
            flushDeferredThemeRefreshIfNeeded()
        }
        .onChange(of: notificationStore.notifications) { _, _ in
            syncCMUXLayoutNotificationBadges()
        }
        .onChange(of: workspace.manualUnreadPanelIds) { _, _ in
            syncCMUXLayoutNotificationBadges()
        }
        .onChange(of: workspace.restoredUnreadPanelIds) { _, _ in
            syncCMUXLayoutNotificationBadges()
        }
        .onChange(of: isWorkspaceManuallyUnread) { _, _ in
            syncCMUXLayoutNotificationBadges()
        }
        .onChange(of: workspaceManualUnreadPanelId) { _, _ in
            syncCMUXLayoutNotificationBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            refreshGhosttyAppearanceConfig(reason: "ghosttyConfigDidReload")
        }
        .onChange(of: colorScheme) { oldValue, newValue in
            // Keep split overlay color/opacity in sync with light/dark theme transitions.
            refreshGhosttyAppearanceConfig(reason: "colorSchemeChanged:\(oldValue)->\(newValue)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            let payloadHex = (notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil"
            let foregroundHex = (notification.userInfo?[GhosttyNotificationKey.foregroundColor] as? NSColor)?.hexString() ?? "nil"
            let eventId = (notification.userInfo?[GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value
            let source = (notification.userInfo?[GhosttyNotificationKey.backgroundSource] as? String) ?? "nil"
            logTheme(
                "theme notification workspace=\(workspace.id.uuidString) event=\(eventId.map(String.init) ?? "nil") source=\(source) payload=\(payloadHex) payloadFg=\(foregroundHex) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appFg=\(GhosttyApp.shared.defaultForegroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
            // Payload ordering can lag across rapid config/theme updates.
            // Resolve from GhosttyApp.shared.defaultBackgroundColor to keep tabs aligned
            // with Ghostty's current runtime theme.
            refreshGhosttyAppearanceConfig(
                reason: "ghosttyDefaultBackgroundDidChange",
                backgroundEventId: eventId,
                backgroundSource: source,
                notificationPayloadHex: payloadHex
            )
        }

        Group {
            if isCanvasOverviewActive {
                WorkspaceCanvasOverviewView(
                    workspace: workspace,
                    controller: workspace.layoutController,
                    appearance: appearance
                ) { tab, paneId in
                    buildPanelContent(tab, paneId, true)
                } emptyPane: { paneId in
                    EmptyPanelView(workspace: workspace, paneId: paneId)
                }
            } else {
            workspaceLayoutView
            }
        }
            .ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])
    }

    private func syncCMUXLayoutNotificationBadges() {
        let manualUnread = workspace.manualUnreadPanelIds
        let restoredUnread = workspace.restoredUnreadPanelIds
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        for paneId in workspace.layoutController.allPaneIds {
            for tab in workspace.layoutController.tabs(inPane: paneId) {
                let panelId = workspace.panelIdFromSurfaceId(tab.id)
                let expectedKind = panelId.flatMap { workspace.panelKind(panelId: $0) }
                let expectedPinned = panelId.map { workspace.isPanelPinned($0) } ?? false
                let shouldShow = panelId.map {
                    Workspace.shouldShowUnreadIndicator(
                        hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                            forTabId: workspace.id,
                            surfaceId: $0
                        ),
                        hasPanelUnreadIndicator: manualUnread.contains($0) || restoredUnread.contains($0),
                        isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                        isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == $0
                    )
                } ?? false
                let kindUpdate: String?? = expectedKind.map { .some($0) }

                if tab.showsNotificationBadge != shouldShow ||
                    tab.isPinned != expectedPinned ||
                    (expectedKind != nil && tab.kind != expectedKind) {
                    workspace.layoutController.updateTab(
                        tab.id,
                        kind: kindUpdate,
                        showsNotificationBadge: shouldShow,
                        isPinned: expectedPinned
                    )
                }
            }
        }
    }

    private var splitZoomRenderIdentity: String {
        workspace.layoutController.zoomedPaneId.map { "zoom:\($0.id.uuidString)" } ?? "unzoomed"
    }

    private static let tmuxWorkspacePaneTopChromeHeight: CGFloat = MinimalModeChromeMetrics.titlebarHeight

    private enum TmuxWorkspacePaneOverlayTrimMode {
        case workspaceLocal
        case windowContent
    }

    private static func tmuxWorkspacePaneContentRect(
        _ rect: CGRect,
        trimMode: TmuxWorkspacePaneOverlayTrimMode
    ) -> CGRect {
        let topInset = min(tmuxWorkspacePaneTopChromeHeight, max(0, rect.height - 1))
        switch trimMode {
        case .workspaceLocal, .windowContent:
            return CGRect(
                x: rect.origin.x,
                y: rect.origin.y + topInset,
                width: rect.width,
                height: max(0, rect.height - topInset)
            )
        }
    }

    private static func tmuxWorkspacePaneRect(
        layoutSnapshot: PaneLayoutSnapshot?,
        paneId: PaneID?,
        includeContainerOffset: Bool,
        trimMode: TmuxWorkspacePaneOverlayTrimMode
    ) -> CGRect? {
        guard let layoutSnapshot,
              let paneId,
              let paneRect = layoutSnapshot.panes
                .first(where: { $0.paneId == paneId.id.uuidString })?
                .frame
                .cgRect else {
            return nil
        }

        let rect: CGRect
        if includeContainerOffset {
            rect = paneRect.offsetBy(
                dx: 0,
                dy: -CGFloat(layoutSnapshot.containerFrame.y)
            )
        } else {
            rect = paneRect.offsetBy(
                dx: -CGFloat(layoutSnapshot.containerFrame.x),
                dy: -CGFloat(layoutSnapshot.containerFrame.y)
            )
        }
        return tmuxWorkspacePaneContentRect(rect, trimMode: trimMode)
    }

    private static func tmuxWorkspacePaneRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: PaneLayoutSnapshot?,
        includeContainerOffset: Bool,
        trimMode: TmuxWorkspacePaneOverlayTrimMode
    ) -> [CGRect] {
        guard let layoutSnapshot else { return [] }
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        return layoutSnapshot.panes.compactMap { pane in
            guard let selectedTabId = pane.selectedTabId,
                  let tabUUID = UUID(uuidString: selectedTabId),
                  let panelId = workspace.panelIdFromSurfaceId(SurfaceID(uuid: tabUUID)) else {
                return nil
            }

            let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                    forTabId: workspace.id,
                    surfaceId: panelId
                ),
                hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panelId) ||
                    workspace.restoredUnreadPanelIds.contains(panelId),
                isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panelId
            )
            guard shouldShowUnread else { return nil }

            let paneRect = pane.frame.cgRect
            let rect: CGRect
            if includeContainerOffset {
                rect = paneRect.offsetBy(
                    dx: 0,
                    dy: -CGFloat(layoutSnapshot.containerFrame.y)
                )
            } else {
                rect = paneRect.offsetBy(
                    dx: -CGFloat(layoutSnapshot.containerFrame.x),
                    dy: -CGFloat(layoutSnapshot.containerFrame.y)
                )
            }
            return tmuxWorkspacePaneContentRect(rect, trimMode: trimMode)
        }
    }

    static func tmuxWorkspacePaneOverlayRect(
        layoutSnapshot: PaneLayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxWorkspacePaneRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId,
            includeContainerOffset: false,
            trimMode: .workspaceLocal
        )
    }

    static func tmuxWorkspacePaneWindowOverlayRect(
        layoutSnapshot: PaneLayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxWorkspacePaneRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId,
            includeContainerOffset: true,
            trimMode: .windowContent
        )
    }

    static func effectiveTmuxPaneLayoutSnapshot(
        cachedSnapshot: PaneLayoutSnapshot?,
        liveSnapshot: PaneLayoutSnapshot?
    ) -> PaneLayoutSnapshot? {
        if let liveSnapshot,
           tmuxPaneLayoutSnapshotHasRenderableGeometry(liveSnapshot) {
            return liveSnapshot
        }
        if let cachedSnapshot,
           tmuxPaneLayoutSnapshotHasRenderableGeometry(cachedSnapshot) {
            return cachedSnapshot
        }
        return cachedSnapshot ?? liveSnapshot
    }

    static func tmuxWorkspacePaneUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: PaneLayoutSnapshot?
    ) -> [CGRect] {
        tmuxWorkspacePaneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: false,
            trimMode: .workspaceLocal
        )
    }

    static func tmuxWorkspacePaneWindowUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: PaneLayoutSnapshot?
    ) -> [CGRect] {
        tmuxWorkspacePaneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: true,
            trimMode: .windowContent
        )
    }

    private static func tmuxPaneLayoutSnapshotHasRenderableGeometry(_ snapshot: PaneLayoutSnapshot) -> Bool {
        snapshot.containerFrame.width > 1 &&
            snapshot.containerFrame.height > 1 &&
            snapshot.panes.contains { pane in
                pane.frame.width > 1 && pane.frame.height > 1
            }
    }

    private func flushDeferredThemeRefreshIfNeeded() {
        guard isWorkspaceVisible,
              let deferredRefresh = deferredThemeRefresh else { return }
        deferredThemeRefresh = nil
        refreshGhosttyAppearanceConfig(
            reason: deferredRefresh.reason,
            backgroundOverride: deferredRefresh.backgroundOverride,
            backgroundEventId: deferredRefresh.backgroundEventId,
            backgroundSource: deferredRefresh.backgroundSource,
            notificationPayloadHex: deferredRefresh.notificationPayloadHex,
            forceInitialApply: deferredRefresh.forceInitialApply
        )
    }

    private func refreshGhosttyAppearanceConfig(
        reason: String,
        backgroundOverride: NSColor? = nil,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil,
        forceInitialApply: Bool = false
    ) {
        guard isWorkspaceVisible else {
            let existing = deferredThemeRefresh
            deferredThemeRefresh = DeferredThemeRefresh(
                reason: reason,
                backgroundOverride: backgroundOverride,
                backgroundEventId: backgroundEventId,
                backgroundSource: backgroundSource,
                notificationPayloadHex: notificationPayloadHex,
                forceInitialApply: forceInitialApply
                    || reason == "onAppear"
                    || existing?.forceInitialApply == true
            )
            return
        }
        deferredThemeRefresh = nil

        let previousSignature = Self.ghosttyAppearanceSignature(
            config,
            usesHostLayerBackground: lastAppliedUsesHostLayerBackground
        )
        let previousBackgroundHex = config.backgroundColor.hexString()
        let next = Self.resolveGhosttyAppearanceConfig(
            reason: reason,
            backgroundOverride: backgroundOverride
        )
        let nextUsesHostLayerBackground = GhosttyApp.shared.usesHostLayerBackground
        let nextSignature = Self.ghosttyAppearanceSignature(
            next,
            usesHostLayerBackground: nextUsesHostLayerBackground
        )
        let eventLabel = backgroundEventId.map(String.init) ?? "nil"
        let sourceLabel = backgroundSource ?? "nil"
        let payloadLabel = notificationPayloadHex ?? "nil"
        let configChanged = previousSignature != nextSignature
        let backgroundChanged = previousBackgroundHex != next.backgroundColor.hexString()
        let opacityChanged = abs(config.backgroundOpacity - next.backgroundOpacity) > 0.0001
        let blurChanged = config.backgroundBlur != next.backgroundBlur
        let shouldForceInitialApply = forceInitialApply || reason == "onAppear"
        let shouldRequestTitlebarRefresh = backgroundChanged || opacityChanged || blurChanged || shouldForceInitialApply
        let shouldApplyChrome = configChanged || shouldForceInitialApply
        let shouldRefreshWindowBackground = backgroundChanged || opacityChanged || blurChanged || shouldForceInitialApply
        if !shouldApplyChrome && !shouldRefreshWindowBackground && !shouldRequestTitlebarRefresh {
            logTheme(
                "theme refresh skip workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel)"
            )
            return
        }
        logTheme(
            "theme refresh begin workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString()) overrideBg=\(backgroundOverride?.hexString() ?? "nil")"
        )
        withTransaction(Transaction(animation: nil)) {
            if configChanged {
                config = next
            }
            if shouldApplyChrome {
                lastAppliedUsesHostLayerBackground = nextUsesHostLayerBackground
            }
            if shouldRequestTitlebarRefresh {
                onThemeRefreshRequest?(
                    reason,
                    backgroundEventId,
                    backgroundSource,
                    notificationPayloadHex
                )
            }
        }
        if !shouldRequestTitlebarRefresh {
            logTheme(
                "theme refresh titlebar-skip workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString())"
            )
        }
        logTheme(
            "theme refresh config-applied workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) configBg=\(config.backgroundColor.hexString())"
        )
        let chromeReason =
            "refreshGhosttyAppearanceConfig:reason=\(reason):event=\(eventLabel):source=\(sourceLabel):payload=\(payloadLabel)"
        if shouldApplyChrome {
            workspace.applyGhosttyChrome(from: next, reason: chromeReason)
        }
        if shouldRefreshWindowBackground {
            if let terminalPanel = workspace.focusedTerminalPanel {
                terminalPanel.applyWindowBackgroundIfActive()
                logTheme(
                    "theme refresh terminal-applied workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) panel=\(workspace.focusedPanelId?.uuidString ?? "nil")"
                )
            } else {
                logTheme(
                    "theme refresh terminal-skipped workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) focusedPanel=\(workspace.focusedPanelId?.uuidString ?? "nil")"
                )
            }
        }
        logTheme(
            "theme refresh end workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) chromeBg=\(workspace.layoutController.configuration.appearance.chromeColors.backgroundHex ?? "nil")"
        )
    }

    private func logTheme(_ message: String) {
        guard GhosttyApp.shared.backgroundLogEnabled else { return }
        GhosttyApp.shared.logBackground(message)
    }
}

extension WorkspaceContentView {
    #if DEBUG
    static func debugPanelLookup(tab: CMUXLayout.SurfaceTab, workspace: Workspace) {
        let found = workspace.panel(for: tab.id) != nil
        if !found {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] PANEL NOT FOUND for tabId=\(tab.id) ws=\(workspace.id) panelCount=\(workspace.panels.count)\n"
            let logPath = "/tmp/cmux-panel-debug.log"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
            }
        }
    }
    #else
    static func debugPanelLookup(tab: CMUXLayout.SurfaceTab, workspace: Workspace) {
        _ = tab
        _ = workspace
    }
    #endif
}

private struct WorkspaceCanvasOverviewView<Content: View, EmptyContent: View>: View {
    @ObservedObject var workspace: Workspace
    @Bindable private var controller: WorkspaceLayoutController
    private let appearance: PanelAppearance
    private let contentBuilder: (SurfaceTab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent
    @FocusState private var hasKeyboardFocus: Bool
    @State private var dragStates: [LayoutItemID: CanvasDragState] = [:]
    @State private var resizeStates: [LayoutItemID: CanvasResizeState] = [:]
    @State private var activeCanvasDragItemID: LayoutItemID?
    @State private var activeAlignmentGuides: [CanvasAlignmentGuide] = []
    @State private var canvasPreviewImages: [SurfaceID: NSImage] = [:]
    @State private var canvasPreviewSnapshotRequests: Set<SurfaceID> = []

    private let canvasPadding: CGFloat = 24
    private let canvasResizeEdgeHitSize: CGFloat = 8
    private let canvasResizeCornerHitSize: CGFloat = 44
    private let minimumFreeformCardWidth: CGFloat = 240
    private let minimumFreeformCardHeight: CGFloat = 170

    private struct CanvasDragState {
        let baseFrame: PixelRect
        let basePortalFrameInWindow: CGRect?
        var frame: PixelRect
        var guides: [CanvasAlignmentGuide]
    }

    private struct CanvasResizeState {
        let baseFrame: PixelRect
        let basePortalFrameInWindow: CGRect?
        var frame: PixelRect
        var guides: [CanvasAlignmentGuide]
    }

    init(
        workspace: Workspace,
        controller: WorkspaceLayoutController,
        appearance: PanelAppearance,
        @ViewBuilder content: @escaping (SurfaceTab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.workspace = workspace
        self.controller = controller
        self.appearance = appearance
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
    }

    var body: some View {
        let scene = controller.canvasSceneSnapshot()
        let document = scene.document
        let renderModes = Dictionary(uniqueKeysWithValues: scene.items.map { ($0.id, $0.renderMode) })
        let items = document.items.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex {
                return lhs.zIndex < rhs.zIndex
            }
            return lhs.id.description < rhs.id.description
        }
        ZStack(alignment: .topLeading) {
            CanvasMetalSceneBackdrop(backgroundColor: appearance.backgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(String(localized: "canvas.mode.canvas", defaultValue: "Canvas"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(canvasForegroundColor.opacity(0.68))
                        .accessibilityIdentifier("WorkspaceCanvasMode.canvas")

                    Text("\(Int(document.viewport.scale * 100))%")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(canvasForegroundColor.opacity(0.45))

                    HStack(spacing: 4) {
                        canvasZoomButton(
                            systemName: "minus.magnifyingglass",
                            label: String(localized: "canvas.zoomOut.help", defaultValue: "Zoom out")
                        ) {
                            _ = workspace.zoomCanvasOverviewOut()
                        }
                        .keyboardShortcut("-", modifiers: [.command])

                        canvasZoomButton(
                            systemName: "arrow.counterclockwise",
                            label: String(localized: "canvas.zoomReset.help", defaultValue: "Reset zoom")
                        ) {
                            _ = workspace.resetCanvasOverviewZoom()
                        }
                        .keyboardShortcut("0", modifiers: [.command])

                        canvasZoomButton(
                            systemName: "plus.magnifyingglass",
                            label: String(localized: "canvas.zoomIn.help", defaultValue: "Zoom in")
                        ) {
                            _ = workspace.zoomCanvasOverviewIn()
                        }
                        .keyboardShortcut("=", modifiers: [.command])
                    }

                    Spacer()
                }
                .padding(.horizontal, canvasPadding)
                .padding(.top, 10)
                .padding(.bottom, 8)

                canvasViewport(items, renderModes: renderModes)
            }
        }
        .accessibilityIdentifier("WorkspaceCanvasOverview")
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onDisappear { endActiveCanvasDragIfNeeded() }
        .onChange(of: document.policy) { _, _ in
            endActiveCanvasDragIfNeeded()
        }
        .backport.onKeyPress(.return) { _ in
            guard shouldHandleCanvasOverviewShortcut() else { return .ignored }
            if workspace.activateFocusedCanvasItem() {
                return .handled
            }
            return .ignored
        }
        .backport.onKeyPress(.escape) { _ in
            guard shouldHandleCanvasOverviewShortcut() else { return .ignored }
            return .handled
        }
        .backport.onKeyPress("-") { modifiers in
            guard modifiers.contains(.command), shouldHandleCanvasOverviewShortcut() else { return .ignored }
            _ = workspace.zoomCanvasOverviewOut()
            return .handled
        }
        .backport.onKeyPress("=") { modifiers in
            guard modifiers.contains(.command), shouldHandleCanvasOverviewShortcut() else { return .ignored }
            _ = workspace.zoomCanvasOverviewIn()
            return .handled
        }
        .backport.onKeyPress("+") { modifiers in
            guard modifiers.contains(.command), shouldHandleCanvasOverviewShortcut() else { return .ignored }
            _ = workspace.zoomCanvasOverviewIn()
            return .handled
        }
        .backport.onKeyPress("0") { modifiers in
            guard modifiers.contains(.command), shouldHandleCanvasOverviewShortcut() else { return .ignored }
            _ = workspace.resetCanvasOverviewZoom()
            return .handled
        }
    }

    private func shouldHandleCanvasOverviewShortcut() -> Bool {
        guard hasKeyboardFocus else { return false }
        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return true }
        if firstResponder is NSTextView || firstResponder is NSTextField {
            return false
        }

        let responderClassName = NSStringFromClass(type(of: firstResponder))
        if responderClassName.contains("WK") || responderClassName.contains("WebView") {
            return false
        }
        return true
    }

    private func canvasZoomButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(canvasForegroundColor.opacity(0.45))
        .help(label)
        .accessibilityLabel(label)
    }

    private func canvasViewport(_ items: [CanvasItem], renderModes: [LayoutItemID: CanvasRenderMode]) -> some View {
        GeometryReader { proxy in
            let scale = freeformScale
            let renderedItems = items.map { item in
                var renderedItem = item
                if let dragState = dragStates[item.id] {
                    renderedItem.frame = dragState.frame
                }
                if let resizeState = resizeStates[item.id] {
                    renderedItem.frame = resizeState.frame
                }
                return renderedItem
            }
            let documentBounds = CanvasGeometryEngine.visibleDocumentRect(
                viewport: controller.canvasViewport,
                viewportSize: proxy.size,
                scale: scale
            )
            let visibleItems = CanvasGeometryEngine.visibleItems(
                renderedItems,
                viewport: controller.canvasViewport,
                viewportSize: proxy.size,
                scale: scale
            )
            let viewportOrigin = CGPoint(
                x: CGFloat(controller.canvasViewport.visibleRect.x),
                y: CGFloat(controller.canvasViewport.visibleRect.y)
            )
            let transform = CanvasTransform(
                documentBounds: documentBounds,
                scale: scale,
                padding: canvasPadding,
                documentOrigin: viewportOrigin
            )

            ZStack(alignment: .topLeading) {
                canvasGridOverlay(transform: transform, contentSize: proxy.size)

                ForEach(visibleItems) { item in
                    let itemFrame = item.frame
                    let canvasRect = transform.canvasRect(forDocumentFrame: itemFrame)
                    let size = freeformCardSize(for: itemFrame, scale: scale)

                    canvasCard(
                        item,
                        dragScale: scale,
                        documentBounds: documentBounds,
                        renderMode: renderModes[item.id] ?? .previewTexture
                    )
                        .frame(width: size.width, height: size.height)
                        .position(
                            x: canvasRect.minX + (size.width / 2),
                            y: canvasRect.minY + (size.height / 2)
                        )
                }

                canvasAlignmentGuideOverlay(activeAlignmentGuides, transform: transform)

                CanvasPanEventMonitorLayer(
                    onPan: { delta in
                        controller.panCanvasViewport(
                            screenDelta: delta,
                            scale: scale,
                            viewportSize: proxy.size
                        )
                        WorkspaceCanvasSurfaceMountManager.synchronizeAll()
                    },
                    onZoom: { delta, anchor in
                        controller.setCanvasViewportScale(
                            zoomedCanvasScale(delta: delta),
                            viewportSize: proxy.size,
                            anchorScreenPoint: anchor
                        )
                        WorkspaceCanvasSurfaceMountManager.synchronizeAll()
                    },
                    onMagnify: { magnification, anchor in
                        controller.setCanvasViewportScale(
                            zoomedCanvasScale(magnification: magnification),
                            viewportSize: proxy.size,
                            anchorScreenPoint: anchor
                        )
                        WorkspaceCanvasSurfaceMountManager.synchronizeAll()
                    },
                    onSmartZoom: { anchor in
                        controller.setCanvasViewportScale(
                            smartZoomedCanvasScale(),
                            viewportSize: proxy.size,
                            anchorScreenPoint: anchor
                        )
                        WorkspaceCanvasSurfaceMountManager.synchronizeAll()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)

                CanvasResizeEventMonitorLayer(
                    onResizeChanged: { itemID, handle, translation in
                        guard let item = currentCanvasInteractionItems().first(where: { $0.id == itemID }) else {
                            return
                        }
                        updateFreeformResize(
                            for: item,
                            scale: scale,
                            handle: handle,
                            translation: translation
                        )
                    },
                    onResizeEnded: { itemID, _ in
                        guard let item = currentCanvasInteractionItems().first(where: { $0.id == itemID }) else {
                            return
                        }
                        endFreeformResize(for: item, scale: scale)
                    }
                )
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)

                CanvasDragEventMonitorLayer(
                    onDragChanged: { itemID, translation in
                        guard let item = currentCanvasInteractionItems().first(where: { $0.id == itemID }) else {
                            return
                        }
                        updateFreeformDrag(
                            for: item,
                            scale: scale,
                            translation: translation
                        )
                    },
                    onDragEnded: { itemID in
                        guard let item = currentCanvasInteractionItems().first(where: { $0.id == itemID }) else {
                            return
                        }
                        endFreeformDrag(for: item)
                    },
                    onClick: { itemID in
                        guard let item = currentCanvasInteractionItems().first(where: { $0.id == itemID }) else {
                            return
                        }
                        activateCanvasItemForInput(item)
                    }
                )
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .transaction { transaction in
                transaction.animation = nil
            }
            .coordinateSpace(name: workspaceCanvasFreeformCoordinateSpace)
            .clipped()
        }
    }

    private func canvasCard(
        _ item: CanvasItem,
        dragScale: CGFloat? = nil,
        documentBounds: CGRect = .zero,
        renderMode: CanvasRenderMode = .previewTexture
    ) -> some View {
        let focused = controller.focusedCanvasItemID == item.id
        let tabs = paneTabs(for: item)
        let selected = selectedTab(for: item) ?? tabs.first
        let paneID = paneID(for: item)
        let title = selected?.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? String(localized: "canvas.card.untitled", defaultValue: "Untitled Surface")
        let registersFreeformDrag = dragScale != nil

        return VStack(alignment: .leading, spacing: 0) {
            cardHeader(
                item: item,
                title: title,
                tabs: tabs,
                selected: selected,
                paneID: paneID,
                registersFreeformDrag: registersFreeformDrag,
                dragScale: dragScale
            )

            livePaneContent(item: item, selected: selected, paneID: paneID, renderMode: renderMode)
        }
        .background(canvasCardBackgroundColor)
        .clipped()
        .overlay {
            Rectangle()
                .stroke(
                    focused ? canvasForegroundColor.opacity(0.34) : appearance.dividerColor.opacity(0.58),
                    lineWidth: 1
                )
        }
        .overlay {
            if let dragScale {
                canvasResizeHitTargets(item: item, scale: dragScale)
            }
        }
        .overlay {
            if dragScale != nil, renderMode != .liveNative1x {
                CanvasDragRegistrationLayer(itemID: item.id)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            canvasHeaderDragHitTarget(
                item: item,
                title: title,
                tabs: tabs,
                paneID: paneID,
                dragScale: dragScale
            )
        }
        .shadow(color: .black.opacity(focused ? 0.20 : 0.10), radius: focused ? 10 : 5, x: 0, y: 4)
        .contentShape(Rectangle())
        .accessibilityIdentifier(accessibilityIdentifier(for: item))
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func canvasHeaderDragHitTarget(
        item: CanvasItem,
        title: String,
        tabs: [SurfaceTab],
        paneID: PaneID?,
        dragScale: CGFloat?
    ) -> some View {
        if dragScale != nil, tabs.count <= 1 {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .contentShape(Rectangle())
                    .frame(
                        width: max(1, proxy.size.width - (canvasResizeCornerHitSize * 2)),
                        height: max(1, 20 - canvasResizeEdgeHitSize)
                    )
                    .offset(x: min(canvasResizeCornerHitSize, max(0, proxy.size.width / 2)), y: canvasResizeEdgeHitSize)
                    .overlay {
                        CanvasDragRegistrationLayer(itemID: item.id)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("WorkspaceCanvasDragLayer.\(item.id.description)")
            }
        }
    }

    @ViewBuilder
    private func cardHeader(
        item: CanvasItem,
        title: String,
        tabs: [SurfaceTab],
        selected: SurfaceTab?,
        paneID: PaneID?,
        registersFreeformDrag: Bool,
        dragScale: CGFloat?
    ) -> some View {
        cardHeaderContent(
            item: item,
            title: title,
            tabs: tabs,
            selected: selected,
            paneID: paneID,
            registersFreeformDrag: registersFreeformDrag,
            dragScale: dragScale
        )
    }

    private func cardHeaderContent(
        item: CanvasItem,
        title: String,
        tabs: [SurfaceTab],
        selected: SurfaceTab?,
        paneID: PaneID?,
        registersFreeformDrag: Bool,
        dragScale: CGFloat?
    ) -> some View {
        HStack(spacing: 4) {
            if tabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(tabs, id: \.id) { tab in
                            canvasTabChip(tab, selected: tab.id == selected?.id, paneID: paneID, item: item)
                        }
                    }
                }
            } else {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(canvasForegroundColor.opacity(0.52))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .background(canvasHeaderBackgroundColor)
        .contentShape(Rectangle())
        .onTapGesture {
            focusCanvasHeader(item: item, paneID: paneID)
        }
    }

    private func focusCanvasHeader(item: CanvasItem, paneID: PaneID?) {
        _ = controller.focusCanvasItem(item.id)
        if let paneID {
            controller.focusPane(paneID)
        }
    }

    @discardableResult
    private func activateCanvasItemForInput(_ item: CanvasItem) -> Bool {
        workspace.activateCanvasItem(item.id)
    }

    private func canvasTabChip(
        _ tab: SurfaceTab,
        selected: Bool,
        paneID: PaneID?,
        item: CanvasItem
    ) -> some View {
        Button {
            _ = controller.focusCanvasItem(item.id)
            if let paneID {
                controller.focusPane(paneID)
            }
            controller.selectSurface(tab.id)
        } label: {
            Text(tab.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(localized: "canvas.preview.surface", defaultValue: "Surface"))
                .font(.system(size: 10, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(selected ? Color.primary.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? canvasForegroundColor.opacity(0.84) : canvasForegroundColor.opacity(0.56))
        .disabled(paneID == nil)
    }

    @ViewBuilder
    private func livePaneContent(
        item: CanvasItem,
        selected: SurfaceTab?,
        paneID: PaneID?,
        renderMode: CanvasRenderMode
    ) -> some View {
        GeometryReader { proxy in
            let visualBounds = CGSize(
                width: max(1, proxy.size.width),
                height: max(1, proxy.size.height)
            )
            let nativeContentSize = canvasNativeContentSize(
                for: item,
                frame: item.frame,
                visualContentSize: visualBounds
            )
            let presentationScale = canvasContentPresentationScale(
                for: item,
                nativeContentSize: nativeContentSize,
                visualContentSize: visualBounds
            )

            ZStack(alignment: .topLeading) {
                if let paneID {
                    if let selected {
                        switch renderMode {
                        case .liveNative1x:
                            contentBuilder(selected, paneID)
                                .frame(width: visualBounds.width, height: visualBounds.height, alignment: .topLeading)
                                .clipped()
                                .background(
                                    CanvasPortalPresentationReporter { frameInWindow in
                                        applyCanvasPortalPresentation(
                                            for: item,
                                            frameInWindow: frameInWindow,
                                            nativeContentSize: nativeContentSize,
                                            scale: presentationScale
                                        )
                                    }
                                )
                        case .previewTexture:
                            canvasPreviewPaneContent(item: item, selected: selected, paneID: paneID)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .onAppear {
                                    captureCanvasPreviewSnapshot(for: selected)
                                    parkCanvasSurface(selected)
                                }
                                .onChange(of: selected.id) { _, _ in
                                    captureCanvasPreviewSnapshot(for: selected)
                                    parkCanvasSurface(selected)
                                }
                        case .unmounted:
                            canvasUnmountedPaneContent(selected: selected)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .onAppear {
                                    parkCanvasSurface(selected)
                                }
                                .onChange(of: selected.id) { _, _ in
                                    parkCanvasSurface(selected)
                                }
                        }
                    } else {
                        emptyPaneBuilder(paneID)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                } else {
                    Text(String(localized: "canvas.card.untitled", defaultValue: "Untitled Surface"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(canvasForegroundColor.opacity(0.62))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .background(canvasContentBackgroundColor)
        .clipped()
    }

    private func canvasPreviewPaneContent(item: CanvasItem, selected: SurfaceTab, paneID: PaneID) -> some View {
        ZStack(alignment: .topLeading) {
            canvasContentBackgroundColor
            if let image = canvasPreviewImages[selected.id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .opacity(0.88)
                    .allowsHitTesting(false)
                if selected.kind == "browser" {
                    canvasBrowserPreviewOmnibar(selected: selected)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(localized: "canvas.preview.surface", defaultValue: "Surface"))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(localized: "canvas.preview.inactive", defaultValue: "Preview"))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(canvasForegroundColor.opacity(0.42))
                }
                .padding(10)
                .foregroundStyle(canvasForegroundColor.opacity(0.62))
            }
        }
        .clipped()
        .accessibilityIdentifier("WorkspaceCanvasPreview.\(item.id.description).\(paneID.id.uuidString)")
    }

    private func canvasBrowserPreviewOmnibar(selected: SurfaceTab) -> some View {
        let text = browserPreviewAddressText(for: selected)
        return HStack(spacing: 5) {
            Image(systemName: "chevron.left")
                .font(.system(size: 8, weight: .semibold))
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                .background(Color.black.opacity(0.24))
        }
        .foregroundStyle(canvasForegroundColor.opacity(0.74))
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(canvasHeaderBackgroundColor.opacity(0.94))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func browserPreviewAddressText(for selected: SurfaceTab) -> String {
        if let browserPanel = workspace.panel(for: selected.id) as? BrowserPanel,
           let urlString = browserPanel.webView.url?.absoluteString,
           !urlString.isEmpty {
            return urlString
        }
        return selected.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "about:blank"
    }

    private func captureCanvasPreviewSnapshot(for selected: SurfaceTab) {
        guard canvasPreviewImages[selected.id] == nil else { return }
        guard let panel = workspace.panel(for: selected.id) else { return }
        if let terminalPanel = panel as? TerminalPanel {
            guard let image = Self.snapshotImage(of: terminalPanel.hostedView) else { return }
            canvasPreviewImages[selected.id] = image
            return
        }

        if let browserPanel = panel as? BrowserPanel {
            guard !canvasPreviewSnapshotRequests.contains(selected.id) else { return }
            canvasPreviewSnapshotRequests.insert(selected.id)
            let surfaceID = selected.id
            browserPanel.takeSnapshot { image in
                Task { @MainActor in
                    canvasPreviewSnapshotRequests.remove(surfaceID)
                    guard let image else { return }
                    canvasPreviewImages[surfaceID] = image
                }
            }
        }
    }

    private static func snapshotImage(of view: NSView) -> NSImage? {
        guard view.window != nil else { return nil }
        let bounds = view.bounds
        guard bounds.width > 1,
              bounds.height > 1,
              bounds.width.isFinite,
              bounds.height.isFinite else {
            return nil
        }

        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func canvasUnmountedPaneContent(selected: SurfaceTab) -> some View {
        ZStack(alignment: .topLeading) {
            canvasContentBackgroundColor
            Text(selected.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(localized: "canvas.preview.surface", defaultValue: "Surface"))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(10)
                .foregroundStyle(canvasForegroundColor.opacity(0.42))
        }
    }

    private func parkCanvasSurface(_ selected: SurfaceTab) {
        WorkspaceCanvasSurfaceMountManager.park(panel: workspace.panel(for: selected.id))
    }

    @ViewBuilder
    private func canvasGridOverlay(transform: CanvasTransform, contentSize: CGSize) -> some View {
        Canvas { context, size in
            let grid = CanvasGrid.freeformDefault
            let screenSpacing = CGFloat(grid.spacing) * transform.scale
            guard screenSpacing >= 4 else { return }

            let minimumDocumentPoint = transform.documentPoint(forCanvasPoint: .zero)
            let maximumDocumentPoint = transform.documentPoint(
                forCanvasPoint: CGPoint(x: size.width, y: size.height)
            )
            let startX = floor(Double(minimumDocumentPoint.x) / grid.spacing) * grid.spacing
            let endX = ceil(Double(maximumDocumentPoint.x) / grid.spacing) * grid.spacing
            let startY = floor(Double(minimumDocumentPoint.y) / grid.spacing) * grid.spacing
            let endY = ceil(Double(maximumDocumentPoint.y) / grid.spacing) * grid.spacing

            func isMajor(_ value: Double) -> Bool {
                Int((value / grid.spacing).rounded()).isMultiple(of: grid.majorEvery)
            }

            var x = startX
            while x <= endX {
                let point = transform.canvasPoint(forDocumentPoint: CGPoint(x: x, y: 0))
                var path = Path()
                path.move(to: CGPoint(x: point.x, y: 0))
                path.addLine(to: CGPoint(x: point.x, y: size.height))
                context.stroke(
                    path,
                    with: .color(canvasForegroundColor.opacity(isMajor(x) ? 0.075 : 0.035)),
                    lineWidth: isMajor(x) ? 1 : 0.5
                )
                x += grid.spacing
            }

            var y = startY
            while y <= endY {
                let point = transform.canvasPoint(forDocumentPoint: CGPoint(x: 0, y: y))
                var path = Path()
                path.move(to: CGPoint(x: 0, y: point.y))
                path.addLine(to: CGPoint(x: size.width, y: point.y))
                context.stroke(
                    path,
                    with: .color(canvasForegroundColor.opacity(isMajor(y) ? 0.075 : 0.035)),
                    lineWidth: isMajor(y) ? 1 : 0.5
                )
                y += grid.spacing
            }
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func canvasAlignmentGuideOverlay(
        _ guides: [CanvasAlignmentGuide],
        transform: CanvasTransform
    ) -> some View {
        ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
            switch guide.axis {
            case .vertical:
                let start = transform.canvasPoint(forDocumentPoint: CGPoint(x: guide.position, y: guide.rangeStart))
                let end = transform.canvasPoint(forDocumentPoint: CGPoint(x: guide.position, y: guide.rangeEnd))
                Rectangle()
                    .fill(Color(nsColor: .controlAccentColor).opacity(0.7))
                    .frame(width: 1, height: max(1, abs(end.y - start.y)))
                    .position(x: start.x, y: (start.y + end.y) / 2)
            case .horizontal:
                let start = transform.canvasPoint(forDocumentPoint: CGPoint(x: guide.rangeStart, y: guide.position))
                let end = transform.canvasPoint(forDocumentPoint: CGPoint(x: guide.rangeEnd, y: guide.position))
                Rectangle()
                    .fill(Color(nsColor: .controlAccentColor).opacity(0.7))
                    .frame(width: max(1, abs(end.x - start.x)), height: 1)
                    .position(x: (start.x + end.x) / 2, y: start.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func currentCanvasInteractionItems() -> [CanvasItem] {
        controller.canvasDocument.items.map { item in
            var renderedItem = item
            if let dragState = dragStates[item.id] {
                renderedItem.frame = dragState.frame
            }
            if let resizeState = resizeStates[item.id] {
                renderedItem.frame = resizeState.frame
            }
            return renderedItem
        }
    }

    private func canvasInteractionConfiguration(scale: CGFloat) -> CanvasInteractionConfiguration {
        CanvasInteractionConfiguration(
            grid: .freeformDefault,
            gridSnapDistanceInScreenPoints: 6,
            alignmentSnapDistanceInScreenPoints: 6,
            guidePadding: 32,
            minimumFrameSize: minimumFreeformFrameSize(scale: scale)
        )
    }

    private func canvasResizeHitTargets(item: CanvasItem, scale: CGFloat) -> some View {
        CanvasResizeInteractionLayer(
            itemID: item.id,
            edgeHitSize: canvasResizeEdgeHitSize,
            cornerHitSize: canvasResizeCornerHitSize,
            onResizeChanged: { handle, translation in
                updateFreeformResize(
                    for: item,
                    scale: scale,
                    handle: handle,
                    translation: translation
                )
            },
            onResizeEnded: { _ in
                endFreeformResize(for: item, scale: scale)
            }
        )
        .help(String(localized: "canvas.resize.help", defaultValue: "Resize"))
        .accessibilityLabel(String(localized: "canvas.resize.help", defaultValue: "Resize"))
        .accessibilityIdentifier("WorkspaceCanvasResizeLayer.\(item.id.description)")
    }

    private func updateFreeformDrag(
        for item: CanvasItem,
        scale: CGFloat,
        translation: CGSize
    ) {
        beginCanvasDragIfNeeded(for: item.id)
        var state = dragStates[item.id] ?? CanvasDragState(
            baseFrame: item.frame,
            basePortalFrameInWindow: currentCanvasPortalFrameInWindow(for: item),
            frame: item.frame,
            guides: []
        )
        let geometry = CanvasGeometryEngine.moveFrame(
            itemID: item.id,
            baseFrame: state.baseFrame,
            canvasTranslation: translation,
            scale: scale,
            items: currentCanvasInteractionItems(),
            configuration: canvasInteractionConfiguration(scale: scale)
        )
        state.frame = geometry.frame
        state.guides = geometry.guides
        dragStates[item.id] = state
        activeAlignmentGuides = geometry.guides
        _ = controller.focusCanvasItem(item.id)
        applyCanvasPortalPresentation(for: item, dragState: state)
    }

    private func endFreeformDrag(for item: CanvasItem) {
        let finalState = dragStates[item.id]
        if let finalState {
            applyCanvasPortalPresentation(for: item, dragState: finalState)
            controller.moveCanvasItem(item.id, to: finalState.frame)
        }
        dragStates[item.id] = nil
        activeAlignmentGuides = []
        endCanvasDrag(for: item.id)
    }

    private func updateFreeformResize(
        for item: CanvasItem,
        scale: CGFloat,
        handle: CanvasResizeHandle,
        translation: CGSize
    ) {
        beginCanvasDragIfNeeded(for: item.id)
        var state = resizeStates[item.id] ?? CanvasResizeState(
            baseFrame: item.frame,
            basePortalFrameInWindow: currentCanvasPortalFrameInWindow(for: item),
            frame: item.frame,
            guides: []
        )
        let geometry = CanvasGeometryEngine.resizeFrame(
            itemID: item.id,
            baseFrame: state.baseFrame,
            canvasTranslation: translation,
            scale: scale,
            handle: handle,
            items: currentCanvasInteractionItems(),
            configuration: canvasInteractionConfiguration(scale: scale)
        )
        state.frame = geometry.frame
        state.guides = geometry.guides
        resizeStates[item.id] = state
        activeAlignmentGuides = geometry.guides
        _ = controller.focusCanvasItem(item.id)
        applyCanvasPortalPresentation(for: item, resizeState: state, scale: scale)
    }

    private func endFreeformResize(for item: CanvasItem, scale: CGFloat) {
        let finalState = resizeStates[item.id]
        if let finalState {
            applyCanvasPortalPresentation(for: item, resizeState: finalState, scale: scale)
            controller.resizeCanvasItem(item.id, to: finalState.frame)
        }
        resizeStates[item.id] = nil
        activeAlignmentGuides = []
        endCanvasDrag(for: item.id)
    }

    private func beginCanvasDragIfNeeded(for itemID: LayoutItemID) {
        if activeCanvasDragItemID == nil {
            TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        }
        activeCanvasDragItemID = itemID
    }

    private func endCanvasDrag(for itemID: LayoutItemID) {
        guard activeCanvasDragItemID == itemID else { return }
        WorkspaceCanvasSurfaceMountManager.synchronizeAll()
        TerminalWindowPortalRegistry.endInteractiveGeometryResize()
        activeCanvasDragItemID = nil
    }

    private func endActiveCanvasDragIfNeeded() {
        let hadActiveDrag = activeCanvasDragItemID != nil
        if hadActiveDrag {
            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
        }
        activeCanvasDragItemID = nil
        dragStates.removeAll()
        resizeStates.removeAll()
        activeAlignmentGuides = []
        clearCanvasPortalFrameOverrides()
        WorkspaceCanvasSurfaceMountManager.synchronizeAll()
    }

    private func applyCanvasPortalPresentation(for item: CanvasItem, dragState: CanvasDragState) {
        guard let basePortalFrameInWindow = dragState.basePortalFrameInWindow else { return }
        let deltaX = CGFloat(dragState.frame.x - dragState.baseFrame.x) * freeformScale
        let deltaY = CGFloat(dragState.frame.y - dragState.baseFrame.y) * freeformScale
        let frameInWindow = basePortalFrameInWindow.offsetBy(
            dx: deltaX,
            dy: -deltaY
        )
        applyCanvasPortalPresentation(
            for: item,
            frameInWindow: frameInWindow,
            frame: dragState.frame,
            visualContentSize: frameInWindow.size
        )
    }

    private func applyCanvasPortalPresentation(
        for item: CanvasItem,
        resizeState: CanvasResizeState,
        scale: CGFloat
    ) {
        guard let basePortalFrameInWindow = resizeState.basePortalFrameInWindow else { return }
        let baseCardSize = freeformCardSize(for: resizeState.baseFrame, scale: scale)
        let nextCardSize = freeformCardSize(for: resizeState.frame, scale: scale)
        let cardOriginDeltaX = CGFloat(resizeState.frame.x - resizeState.baseFrame.x) * scale
        let cardOriginDeltaY = CGFloat(resizeState.frame.y - resizeState.baseFrame.y) * scale
        let nextPortalWidth = max(1, basePortalFrameInWindow.width + nextCardSize.width - baseCardSize.width)
        let nextPortalHeight = max(1, basePortalFrameInWindow.height + nextCardSize.height - baseCardSize.height)
        let frameInWindow = CGRect(
            x: basePortalFrameInWindow.minX + cardOriginDeltaX,
            y: basePortalFrameInWindow.maxY - cardOriginDeltaY - nextPortalHeight,
            width: nextPortalWidth,
            height: nextPortalHeight
        )
        applyCanvasPortalPresentation(
            for: item,
            frameInWindow: frameInWindow,
            frame: resizeState.frame,
            visualContentSize: frameInWindow.size
        )
    }

    private func applyCanvasPortalPresentation(
        for item: CanvasItem,
        frameInWindow: CGRect?,
        frame: PixelRect,
        visualContentSize: CGSize
    ) {
        let nativeContentSize = canvasNativeContentSize(
            for: item,
            frame: frame,
            visualContentSize: visualContentSize
        )
        applyCanvasPortalPresentation(
            for: item,
            frameInWindow: frameInWindow,
            nativeContentSize: nativeContentSize,
            scale: canvasContentPresentationScale(
                for: item,
                nativeContentSize: nativeContentSize,
                visualContentSize: visualContentSize
            )
        )
    }

    private func applyCanvasPortalPresentation(
        for item: CanvasItem,
        frameInWindow: CGRect?,
        nativeContentSize: CGSize,
        scale: CGFloat
    ) {
        guard let selected = selectedTab(for: item),
              let panel = workspace.panel(for: selected.id) else { return }
        WorkspaceCanvasSurfaceMountManager.apply(
            panel: panel,
            frameInWindow: frameInWindow,
            nativeContentSize: nativeContentSize,
            scale: scale
        )
    }

    private func clearCanvasPortalFrameOverrides() {
        WorkspaceCanvasSurfaceMountManager.clearTransientOverrides()
    }

    private func currentCanvasPortalFrameInWindow(for item: CanvasItem) -> CGRect? {
        guard let selected = selectedTab(for: item),
              let panel = workspace.panel(for: selected.id) else { return nil }
        return WorkspaceCanvasSurfaceMountManager.currentFrameInWindow(panel: panel)
    }

    private var canvasBackgroundColor: Color {
        Color(nsColor: appearance.backgroundColor)
    }

    private var canvasCardBackgroundColor: Color {
        Color(nsColor: appearance.backgroundColor)
    }

    private var canvasContentBackgroundColor: Color {
        Color(nsColor: appearance.backgroundColor)
    }

    private var canvasHeaderBackgroundColor: Color {
        Color(nsColor: appearance.foregroundColor).opacity(0.045)
    }

    private var canvasForegroundColor: Color {
        Color(nsColor: appearance.foregroundColor)
    }

    private var freeformScale: CGFloat {
        CGFloat(CanvasViewportZoom.presentationScale(for: controller.canvasViewport))
    }

    private func zoomedCanvasScale(delta: Double) -> Double {
        CanvasViewportZoom.scaleAfterWheel(deltaY: delta, currentScale: controller.canvasViewport.scale)
    }

    private func zoomedCanvasScale(magnification: Double) -> Double {
        CanvasViewportZoom.scaleAfterMagnification(magnification, currentScale: controller.canvasViewport.scale)
    }

    private func smartZoomedCanvasScale() -> Double {
        CanvasViewportZoom.smartZoomScale(currentScale: controller.canvasViewport.scale)
    }

    private func freeformCardSize(for frame: PixelRect, scale: CGFloat) -> CGSize {
        CanvasGeometryEngine.cardSize(
            for: frame,
            scale: scale,
            minimumDisplaySize: CGSize(width: minimumFreeformCardWidth, height: minimumFreeformCardHeight)
        )
    }

    private func canvasNativeContentSize(
        for item: CanvasItem,
        frame: PixelRect,
        visualContentSize: CGSize
    ) -> CGSize {
        let visualSize = CGSize(
            width: max(1, visualContentSize.width),
            height: max(1, visualContentSize.height)
        )
        if item.isNativeResolution {
            return visualSize
        }
        return CGSize(
            width: max(1, CGFloat(frame.width)),
            height: max(1, CGFloat(frame.height))
        )
    }

    private func canvasContentPresentationScale(
        for item: CanvasItem,
        nativeContentSize: CGSize,
        visualContentSize: CGSize
    ) -> CGFloat {
        if item.isNativeResolution {
            return 1
        }
        guard nativeContentSize.width > 0,
              nativeContentSize.height > 0,
              visualContentSize.width > 0,
              visualContentSize.height > 0 else {
            return 1
        }
        return max(
            0.0001,
            min(
                visualContentSize.width / nativeContentSize.width,
                visualContentSize.height / nativeContentSize.height
            )
        )
    }

    private func minimumFreeformFrameSize(scale: CGFloat) -> CGSize {
        CanvasGeometryEngine.minimumFrameSize(
            scale: scale,
            minimumDisplaySize: CGSize(width: minimumFreeformCardWidth, height: minimumFreeformCardHeight)
        )
    }

    private func paneTabs(for item: CanvasItem) -> [SurfaceTab] {
        switch item.content {
        case .pane(let paneID):
            return controller.tabs(inPane: paneID)
        case .surface(let surfaceID):
            return controller.surface(surfaceID).map { [$0] } ?? []
        case .group:
            return []
        }
    }

    private func selectedTab(for item: CanvasItem) -> SurfaceTab? {
        switch item.content {
        case .pane(let paneID):
            return controller.selectedTab(inPane: paneID)
        case .surface(let surfaceID):
            return controller.surface(surfaceID)
        case .group:
            return nil
        }
    }

    private func paneID(for item: CanvasItem) -> PaneID? {
        switch item.content {
        case .pane(let paneID):
            return paneID
        case .surface(let surfaceID):
            return controller.allPaneIds.first { paneID in
                controller.tabs(inPane: paneID).contains { $0.id == surfaceID }
            }
        case .group:
            return nil
        }
    }

    private func accessibilityIdentifier(for item: CanvasItem) -> String {
        switch item.content {
        case .pane(let paneID):
            return "WorkspaceCanvasCard.\(paneID.id.uuidString)"
        case .surface(let surfaceID):
            return "WorkspaceCanvasSurfaceCard.\(surfaceID.uuid.uuidString)"
        case .group:
            return "WorkspaceCanvasGroupCard.\(item.id.id.uuidString)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// View shown for empty panes
struct EmptyPanelView: View {
    @ObservedObject var workspace: Workspace
    let paneId: PaneID
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    private struct ShortcutHint: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.18), in: Capsule())
        }
    }

    private func focusPane() {
        workspace.layoutController.focusPane(paneId)
    }

    private func createTerminal() {
        #if DEBUG
        cmuxDebugLog("emptyPane.newTerminal pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newTerminalSurface(inPane: paneId)
    }

    private func createBrowser() {
        #if DEBUG
        cmuxDebugLog("emptyPane.newBrowser pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newBrowserSurface(inPane: paneId)
    }

    private var newSurfaceShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .newSurface)
    }

    private var openBrowserShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .openBrowser)
    }

    @ViewBuilder
    private func emptyPaneActionButton(
        title: String,
        systemImage: String,
        shortcut: StoredShortcut,
        action: @escaping () -> Void
    ) -> some View {
        if let key = shortcut.keyEquivalent {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Empty Panel")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                emptyPaneActionButton(
                    title: "Terminal",
                    systemImage: "terminal.fill",
                    shortcut: newSurfaceShortcut,
                    action: createTerminal
                )

                emptyPaneActionButton(
                    title: "Browser",
                    systemImage: "globe",
                    shortcut: openBrowserShortcut,
                    action: createBrowser
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyBackgroundTheme.currentColor()))
#if DEBUG
        .onAppear {
            DebugUIEventCounters.emptyPanelAppearCount += 1
        }
#endif
    }
}

#if DEBUG
@MainActor
enum DebugUIEventCounters {
    static var emptyPanelAppearCount: Int = 0

    static func resetEmptyPanelAppearCount() {
        emptyPanelAppearCount = 0
    }
}
#endif
