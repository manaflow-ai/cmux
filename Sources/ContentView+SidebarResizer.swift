import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Sidebar resizer handles, width clamping, cursor
extension ContentView {
    private static let fixedSidebarResizeCursor = NSCursor(
        image: NSCursor.resizeLeftRight.image,
        hotSpot: NSCursor.resizeLeftRight.hotSpot
    )
    private static let maximumSidebarWidthRatio: CGFloat = 1.0 / 3.0
    private static let minimumRightSidebarWidth: CGFloat = 276
    private static let maximumRightSidebarWidth: CGFloat = 1200
    private static let minimumTerminalWidthWithRightSidebar: CGFloat = 360

    var minimumSidebarWidth: CGFloat {
        CGFloat(SessionPersistencePolicy.sanitizedMinimumSidebarWidth(sidebarMinimumWidthSetting))
    }

    enum SidebarResizerHandle: Hashable {
        case divider
        case explorerDivider
    }

    /// Returns the current drag width, start width capture, width update, and drag end cleanup for a resizer handle.
    private func resizerConfig(for handle: SidebarResizerHandle, availableWidth: CGFloat) -> (
        currentWidth: CGFloat,
        captureStart: () -> Void,
        updateWidth: (CGFloat) -> Void,
        finishDrag: () -> Void
    ) {
        switch handle {
        case .divider:
            return (
                currentWidth: sidebarWidth,
                captureStart: { sidebarDragStartWidth = sidebarWidth },
                updateWidth: { translation in
                    let startWidth = sidebarDragStartWidth ?? sidebarWidth
                    let nextWidth = Self.clampedSidebarWidth(
                        startWidth + translation,
                        maximumWidth: maxSidebarWidth(availableWidth: availableWidth),
                        minimumWidth: minimumSidebarWidth
                    )
                    withTransaction(Transaction(animation: nil)) {
                        sidebarWidth = nextWidth
                    }
                },
                finishDrag: { sidebarDragStartWidth = nil }
            )
        case .explorerDivider:
            return (
                currentWidth: fileExplorerWidth,
                captureStart: { fileExplorerDragStartWidth = fileExplorerWidth },
                updateWidth: { translation in
                    let startWidth = fileExplorerDragStartWidth ?? fileExplorerWidth
                    let nextWidth = Self.clampedRightSidebarWidth(
                        startWidth - translation,
                        availableWidth: availableWidth
                    )
                    withTransaction(Transaction(animation: nil)) {
                        fileExplorerWidth = nextWidth
                    }
                },
                finishDrag: {
                    fileExplorerDragStartWidth = nil
                    fileExplorerState.width = fileExplorerWidth
                }
            )
        }
    }

    private func maxSidebarWidth(availableWidth: CGFloat? = nil) -> CGFloat {
        let resolvedAvailableWidth = availableWidth
            ?? observedWindow?.contentView?.bounds.width
            ?? observedWindow?.contentLayoutRect.width
            ?? NSApp.keyWindow?.contentView?.bounds.width
            ?? NSApp.keyWindow?.contentLayoutRect.width
        if let resolvedAvailableWidth, resolvedAvailableWidth > 0 {
            return max(minimumSidebarWidth, resolvedAvailableWidth * Self.maximumSidebarWidthRatio)
        }

        let fallbackScreenWidth = NSApp.keyWindow?.screen?.frame.width
            ?? NSScreen.main?.frame.width
            ?? 1920
        return max(minimumSidebarWidth, fallbackScreenWidth * Self.maximumSidebarWidthRatio)
    }

    static func clampedSidebarWidth(
        _ candidate: CGFloat,
        maximumWidth: CGFloat,
        minimumWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultMinimumSidebarWidth)
    ) -> CGFloat {
        let sanitizedMaximumWidth = max(minimumWidth, maximumWidth.isFinite ? maximumWidth : minimumWidth)
        guard candidate.isFinite else {
            return max(
                minimumWidth,
                min(sanitizedMaximumWidth, CGFloat(SessionPersistencePolicy.defaultSidebarWidth))
            )
        }
        return max(minimumWidth, min(sanitizedMaximumWidth, candidate))
    }

    static func clampedRightSidebarWidth(_ candidate: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let minimumWidth = Self.minimumRightSidebarWidth
        let sanitizedCandidate = candidate.isFinite ? candidate : 220
        let sanitizedAvailableWidth = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 1920
        let availableWidthCap = sanitizedAvailableWidth - Self.minimumTerminalWidthWithRightSidebar
        let maximumWidth = min(
            Self.maximumRightSidebarWidth,
            max(minimumWidth, availableWidthCap)
        )
        return max(minimumWidth, min(maximumWidth, sanitizedCandidate))
    }

    func clampSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = Self.clampedSidebarWidth(
            sidebarWidth,
            maximumWidth: maxSidebarWidth(availableWidth: availableWidth),
            minimumWidth: minimumSidebarWidth
        )
        guard abs(nextWidth - sidebarWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            sidebarWidth = nextWidth
        }
    }

    func normalizedSidebarWidth(_ candidate: CGFloat) -> CGFloat {
        Self.clampedSidebarWidth(
            candidate,
            maximumWidth: maxSidebarWidth(),
            minimumWidth: minimumSidebarWidth
        )
    }

    private func resolvedRightSidebarAvailableWidth(_ availableWidth: CGFloat? = nil) -> CGFloat {
        if let availableWidth {
            return availableWidth
        }
        if let width = observedWindow?.contentView?.bounds.width {
            return width
        }
        if let width = observedWindow?.contentLayoutRect.width {
            return width
        }
        if let width = NSApp.keyWindow?.contentView?.bounds.width {
            return width
        }
        if let width = NSApp.keyWindow?.contentLayoutRect.width {
            return width
        }
        if let width = NSApp.keyWindow?.screen?.frame.width {
            return width
        }
        if let width = NSScreen.main?.frame.width {
            return width
        }
        return 1920
    }

    func normalizedRightSidebarWidth(_ candidate: CGFloat, availableWidth: CGFloat? = nil) -> CGFloat {
        Self.clampedRightSidebarWidth(
            candidate,
            availableWidth: resolvedRightSidebarAvailableWidth(availableWidth)
        )
    }

    func clampRightSidebarWidthIfNeeded(availableWidth: CGFloat? = nil) {
        let nextWidth = normalizedRightSidebarWidth(fileExplorerWidth, availableWidth: availableWidth)
        guard abs(nextWidth - fileExplorerWidth) > 0.5 else { return }
        withTransaction(Transaction(animation: nil)) {
            fileExplorerWidth = nextWidth
        }
        fileExplorerState.width = nextWidth
    }

    private func activateSidebarResizerCursor() {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        sidebarResizerCursorReleaseWorkItem = nil
        isSidebarResizerCursorActive = true
        Self.fixedSidebarResizeCursor.set()
    }

    private func releaseSidebarResizerCursorIfNeeded(force: Bool = false) {
        let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let shouldKeepCursor = !force
            && (isResizerDragging || isResizerBandActive || !hoveredResizerHandles.isEmpty || isLeftMouseButtonDown)
        guard !shouldKeepCursor else { return }
        guard isSidebarResizerCursorActive else { return }
        isSidebarResizerCursorActive = false
        NSCursor.arrow.set()
    }

    private func scheduleSidebarResizerCursorRelease(force: Bool = false, delay: TimeInterval = 0) {
        sidebarResizerCursorReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            sidebarResizerCursorReleaseWorkItem = nil
            releaseSidebarResizerCursorIfNeeded(force: force)
        }
        sidebarResizerCursorReleaseWorkItem = workItem
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    private func dividerBandContains(pointInContent point: NSPoint, contentBounds: NSRect) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        if sidebarState.isVisible,
           SidebarResizeInteraction.Edge.leading.hitRange(dividerX: sidebarWidth).contains(point.x) {
            return true
        }

        let rightDividerX = contentBounds.maxX - rightSidebarWidth
        return rightSidebarVisible &&
            SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: rightDividerX).contains(point.x)
    }

    func updateSidebarResizerBandState(using _: NSEvent? = nil) {
        guard sidebarState.isVisible || rightSidebarVisible,
              let window = observedWindow,
              let contentView = window.contentView else {
            isResizerBandActive = false
            scheduleSidebarResizerCursorRelease(force: true)
            return
        }

        // Use live global pointer location instead of per-event coordinates.
        // Overlapping tracking areas (notably WKWebView) can deliver stale/jittery
        // event locations during cursor updates, which causes visible cursor flicker.
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        let isInDividerBand = dividerBandContains(pointInContent: pointInContent, contentBounds: contentView.bounds)
        isResizerBandActive = isInDividerBand

        if isInDividerBand || isResizerDragging {
            activateSidebarResizerCursor()
            startSidebarResizerCursorStabilizer()
            // AppKit cursorUpdate handlers from overlapped portal/web views can run
            // after our local monitor callback and temporarily reset the cursor.
            // Re-assert on the next runloop turn to keep the resize cursor stable.
            DispatchQueue.main.async {
                Self.fixedSidebarResizeCursor.set()
            }
        } else {
            stopSidebarResizerCursorStabilizer()
            scheduleSidebarResizerCursorRelease()
        }
    }

    private func startSidebarResizerCursorStabilizer() {
        guard sidebarResizerCursorStabilizer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler {
            updateSidebarResizerBandState()
            if isResizerBandActive || isResizerDragging {
                Self.fixedSidebarResizeCursor.set()
            } else {
                stopSidebarResizerCursorStabilizer()
            }
        }
        sidebarResizerCursorStabilizer = timer
        timer.resume()
    }

    private func stopSidebarResizerCursorStabilizer() {
        sidebarResizerCursorStabilizer?.cancel()
        sidebarResizerCursorStabilizer = nil
    }

    func installSidebarResizerPointerMonitorIfNeeded() {
        guard sidebarResizerPointerMonitor == nil else { return }
        observedWindow?.acceptsMouseMovedEvents = true
        sidebarResizerPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .mouseEntered,
                .mouseExited,
                .cursorUpdate,
                .appKitDefined,
                .systemDefined,
                .leftMouseDown,
                .leftMouseUp,
                .leftMouseDragged,
            ]
        ) { event in
            updateSidebarResizerBandState(using: event)
            let shouldOverrideCursorEvent: Bool = {
                switch event.type {
                case .cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited, .appKitDefined, .systemDefined:
                    return true
                default:
                    return false
                }
            }()
            if shouldOverrideCursorEvent, (isResizerBandActive || isResizerDragging) {
                // Consume hover motion in divider band so overlapped views cannot
                // continuously reassert their own cursor while we are resizing.
                activateSidebarResizerCursor()
                Self.fixedSidebarResizeCursor.set()
                return nil
            }
            return event
        }
        updateSidebarResizerBandState()
    }

    func removeSidebarResizerPointerMonitor() {
        if let monitor = sidebarResizerPointerMonitor {
            NSEvent.removeMonitor(monitor)
            sidebarResizerPointerMonitor = nil
        }
        isResizerBandActive = false
        isSidebarResizerCursorActive = false
        stopSidebarResizerCursorStabilizer()
        scheduleSidebarResizerCursorRelease(force: true)
    }

    private func sidebarResizerHandleOverlay(
        _ handle: SidebarResizerHandle,
        width: CGFloat,
        availableWidth: CGFloat,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredResizerHandles.insert(handle)
                    activateSidebarResizerCursor()
                } else {
                    hoveredResizerHandles.remove(handle)
                    let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    if isLeftMouseButtonDown {
                        // Keep resize cursor pinned through mouse-down so AppKit
                        // cursorUpdate events from overlapping views do not flash arrow.
                        activateSidebarResizerCursor()
                    } else {
                        // Give mouse-down + drag-start callbacks time to establish state
                        // before any cursor pop is attempted.
                        scheduleSidebarResizerCursorRelease(delay: 0.05)
                    }
                }
                updateSidebarResizerBandState()
            }
            .onDisappear {
                hoveredResizerHandles.remove(handle)
                if isResizerDragging {
                    TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                    isResizerDragging = false
                }
                sidebarDragStartWidth = nil
                isResizerBandActive = false
                scheduleSidebarResizerCursorRelease(force: true)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let config = resizerConfig(for: handle, availableWidth: availableWidth)
                        if !isResizerDragging {
                            TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
                            isResizerDragging = true
                            config.captureStart()
                        }
                        activateSidebarResizerCursor()
                        config.updateWidth(value.translation.width)
                    }
                    .onEnded { _ in
                        if isResizerDragging {
                            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                            isResizerDragging = false
                            let config = resizerConfig(for: handle, availableWidth: availableWidth)
                            config.finishDrag()
                        }
                        activateSidebarResizerCursor()
                        scheduleSidebarResizerCursorRelease()
                    }
            )
            .modifier(SidebarResizerAccessibilityModifier(accessibilityIdentifier: accessibilityIdentifier))
    }

    private func placedSidebarResizerOverlay(
        handle: SidebarResizerHandle,
        edge: SidebarResizeInteraction.Edge,
        accessibilityIdentifier: String,
        dividerX: @escaping (CGFloat) -> CGFloat
    ) -> some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width)
            let resolvedDividerX = min(max(dividerX(totalWidth), 0), totalWidth)
            let leadingWidth = max(0, edge.handleX(dividerX: resolvedDividerX))

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leadingWidth)
                    .allowsHitTesting(false)

                sidebarResizerHandleOverlay(
                    handle,
                    width: SidebarResizeInteraction.totalHitWidth,
                    availableWidth: totalWidth,
                    accessibilityIdentifier: accessibilityIdentifier
                )

                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
            .frame(width: totalWidth, height: proxy.size.height, alignment: .leading)
        }
    }

    var sidebarResizerOverlay: some View {
        placedSidebarResizerOverlay(
            handle: .divider,
            edge: .leading,
            accessibilityIdentifier: "SidebarResizer",
            dividerX: { totalWidth in min(max(sidebarWidth, 0), totalWidth) }
        )
    }

    var rightSidebarResizerOverlay: some View {
        placedSidebarResizerOverlay(
            handle: .explorerDivider,
            edge: .trailing,
            accessibilityIdentifier: "RightSidebarResizer",
            dividerX: { totalWidth in totalWidth - rightSidebarWidth }
        )
    }

}
