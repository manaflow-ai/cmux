import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Drop zone overlay and file drops
extension GhosttySurfaceScrollView {
    private func dropZoneOverlayContainerView() -> NSView {
        superview ?? self
    }

    func bringPaneDropTargetToFrontIfNeeded() {
        if paneDropTargetView.superview !== self || subviews.last !== paneDropTargetView {
            addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
        }
    }

    func attachDropZoneOverlayIfNeeded() {
        // Keep the hover indicator outside the hosted terminal subtree so it stays purely additive
        // and cannot invalidate the scroll/surface layout that Ghostty renders into.
        let container = dropZoneOverlayContainerView()
        if dropZoneOverlayView.superview !== container {
            dropZoneOverlayView.removeFromSuperview()
            if container === self {
                addSubview(dropZoneOverlayView, positioned: .above, relativeTo: nil)
            } else {
                container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: self)
            }
#if DEBUG
            logDropZoneOverlay(event: "attach", zone: activeDropZone ?? pendingDropZone, frame: dropZoneOverlayView.frame)
#endif
            return
        }

        guard container !== self else { return }
        guard let hostedIndex = container.subviews.firstIndex(of: self),
              let overlayIndex = container.subviews.firstIndex(of: dropZoneOverlayView),
              overlayIndex <= hostedIndex else { return }
        container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: self)
    }

    func applyDropZoneOverlayFrame(_ frame: CGRect) {
        if Self.rectApproximatelyEqual(dropZoneOverlayView.frame, frame) { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropZoneOverlayView.frame = frame
        CATransaction.commit()
    }

#if DEBUG
    private static func isDragMouseEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private func hasActiveDragLoggingContext() -> Bool {
        let pasteboardTypes = NSPasteboard(name: .drag).types
        let hasTabDrag = pasteboardTypes?.contains(Self.tabTransferPasteboardType) == true
        let hasSidebarDrag = pasteboardTypes?.contains(Self.sidebarTabReorderPasteboardType) == true
        let eventType = NSApp.currentEvent?.type
        return activeDropZone != nil ||
            pendingDropZone != nil ||
            ((hasTabDrag || hasSidebarDrag) && Self.isDragMouseEvent(eventType))
    }

    func logDragGeometryChange(event: String, old: CGPoint, new: CGPoint) {
        guard hasActiveDragLoggingContext() else { return }

        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let signature =
            "\(event)|\(surface)|\(String(format: "%.1f,%.1f", old.x, old.y))|" +
            "\(String(format: "%.1f,%.1f", new.x, new.y))|\(overlaySuperviewClass)|\(dropZoneOverlayView.isHidden ? 1 : 0)"
        guard lastDragGeometryLogSignature != signature else { return }
        lastDragGeometryLogSignature = signature
        cmuxDebugLog(
            "terminal.dragGeometry event=\(event) surface=\(surface) " +
            "old=\(String(format: "%.1f,%.1f", old.x, old.y)) " +
            "new=\(String(format: "%.1f,%.1f", new.x, new.y)) " +
            "overlaySuper=\(overlaySuperviewClass) " +
            "overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "overlayHidden=\(dropZoneOverlayView.isHidden ? 1 : 0)"
        )
    }

    func logLayoutDuringActiveDrag(targetSize: CGSize) {
        let pasteboardTypes = NSPasteboard(name: .drag).types
        let hasTabDrag = pasteboardTypes?.contains(Self.tabTransferPasteboardType) == true
        let hasSidebarDrag = pasteboardTypes?.contains(Self.sidebarTabReorderPasteboardType) == true
        let eventType = NSApp.currentEvent?.type
        let hasActiveDrag =
            activeDropZone != nil ||
            pendingDropZone != nil ||
            ((hasTabDrag || hasSidebarDrag) && Self.isDragMouseEvent(eventType))
        guard hasActiveDrag else { return }

        dragLayoutLogSequence &+= 1
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let activeZone = activeDropZone.map { String(describing: $0) } ?? "none"
        let pendingZone = pendingDropZone.map { String(describing: $0) } ?? "none"
        let event = eventType.map { String(describing: $0) } ?? "nil"
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog(
            "terminal.layout.drag surface=\(surface) seq=\(dragLayoutLogSequence) " +
            "activeZone=\(activeZone) pendingZone=\(pendingZone) " +
            "hasTabDrag=\(hasTabDrag ? 1 : 0) hasSidebarDrag=\(hasSidebarDrag ? 1 : 0) " +
            "event=\(event) inWindow=\(window != nil ? 1 : 0) " +
            "overlaySuper=\(overlaySuperviewClass) overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "scrollOrigin=\(String(format: "%.1f,%.1f", scrollView.contentView.bounds.origin.x, scrollView.contentView.bounds.origin.y)) " +
            "surfaceOrigin=\(String(format: "%.1f,%.1f", surfaceView.frame.origin.x, surfaceView.frame.origin.y)) " +
            "bounds=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
            "target=\(String(format: "%.1fx%.1f", targetSize.width, targetSize.height))"
        )
    }
#endif

    func dropZoneOverlayFrame(for zone: DropZone, in size: CGSize) -> CGRect {
        let localFrame = PaneDropRouting.compactOverlayFrame(for: zone, in: size)

        let container = dropZoneOverlayView.superview ?? superview
        guard let container, container !== self else { return localFrame }
        return container.convert(localFrame, from: self)
    }

    static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    func setDropZoneOverlay(zone: DropZone?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setDropZoneOverlay(zone: zone)
            }
            return
        }

        if let zone, (bounds.width <= 2 || bounds.height <= 2) {
            pendingDropZone = zone
#if DEBUG
            logDropZoneOverlay(event: "deferZeroBounds", zone: zone, frame: nil)
#endif
            return
        }

        let previousZone = activeDropZone
        activeDropZone = zone
        pendingDropZone = nil

        if let zone {
#if DEBUG
            if window == nil {
                logDropZoneOverlay(event: "showNoWindow", zone: zone, frame: nil)
            }
#endif
            attachDropZoneOverlayIfNeeded()
            let targetFrame = dropZoneOverlayFrame(for: zone, in: bounds.size)
            let previousFrame = dropZoneOverlayView.frame
            let isSameFrame = Self.rectApproximatelyEqual(previousFrame, targetFrame)
            let needsFrameUpdate = !isSameFrame
            let zoneChanged = previousZone != zone

            if !dropZoneOverlayView.isHidden && !needsFrameUpdate && !zoneChanged {
                return
            }

            dropZoneOverlayAnimationGeneration &+= 1
            dropZoneOverlayView.layer?.removeAllAnimations()

            if dropZoneOverlayView.isHidden {
                applyDropZoneOverlayFrame(targetFrame)
                dropZoneOverlayView.alphaValue = 0
                dropZoneOverlayView.isHidden = false
#if DEBUG
                recordDropOverlayShowAnimation()
#endif
#if DEBUG
                logDropZoneOverlay(event: "show", zone: zone, frame: targetFrame)
#endif

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    dropZoneOverlayView.animator().alphaValue = 1
                } completionHandler: { [weak self] in
#if DEBUG
                    guard let self else { return }
                    guard self.activeDropZone == zone else { return }
                    self.logDropZoneOverlay(event: "showComplete", zone: zone, frame: targetFrame)
#endif
                }
                return
            }

#if DEBUG
            if needsFrameUpdate || zoneChanged {
                logDropZoneOverlay(event: "update", zone: zone, frame: targetFrame)
            }
#endif
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if needsFrameUpdate {
                    dropZoneOverlayView.animator().frame = targetFrame
                }
                if dropZoneOverlayView.alphaValue < 1 {
                    dropZoneOverlayView.animator().alphaValue = 1
                }
            }
        } else {
            guard !dropZoneOverlayView.isHidden else { return }
            dropZoneOverlayAnimationGeneration &+= 1
            let animationGeneration = dropZoneOverlayAnimationGeneration
            dropZoneOverlayView.layer?.removeAllAnimations()
#if DEBUG
            logDropZoneOverlay(event: "hide", zone: nil, frame: nil)
#endif

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dropZoneOverlayView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self else { return }
                guard self.dropZoneOverlayAnimationGeneration == animationGeneration else { return }
                guard self.activeDropZone == nil else { return }
                self.dropZoneOverlayView.isHidden = true
                self.dropZoneOverlayView.alphaValue = 1
#if DEBUG
                self.logDropZoneOverlay(event: "hideComplete", zone: nil, frame: nil)
#endif
            }
        }
    }

    func setPaneDropContext(_ context: TerminalPaneDropContext?) {
        paneDropTargetView.dropContext = context
        if context == nil {
            paneDropTargetView.draggingExited(nil)
        }
    }

    func paneDropTargetForDrop(at localPoint: NSPoint) -> TerminalPaneDropTargetView? {
        guard bounds.contains(localPoint) else { return nil }
        let pointInTarget = paneDropTargetView.convert(localPoint, from: self)
        guard paneDropTargetView.bounds.contains(pointInTarget) else { return nil }
        guard !paneDropTargetView.shouldDeferToPaneTabBar(at: pointInTarget) else { return nil }
        return paneDropTargetView
    }

#if DEBUG
    func logDropZoneOverlay(event: String, zone: DropZone?, frame: CGRect?) {
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let zoneText = zone.map { String(describing: $0) } ?? "none"
        let boundsText = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let scrollOriginText = String(
            format: "%.1f,%.1f",
            scrollView.contentView.bounds.origin.x,
            scrollView.contentView.bounds.origin.y
        )
        let surfaceOriginText = String(
            format: "%.1f,%.1f",
            surfaceView.frame.origin.x,
            surfaceView.frame.origin.y
        )
        let frameText: String
        if let frame {
            frameText = String(
                format: "%.1f,%.1f %.1fx%.1f",
                frame.origin.x, frame.origin.y, frame.width, frame.height
            )
        } else {
            frameText = "-"
        }
        let signature =
            "\(event)|\(surface)|\(zoneText)|\(boundsText)|\(frameText)|\(overlaySuperviewClass)|" +
            "\(scrollOriginText)|\(surfaceOriginText)|\(dropZoneOverlayView.isHidden ? 1 : 0)"
        guard lastDropZoneOverlayLogSignature != signature else { return }
        lastDropZoneOverlayLogSignature = signature
        cmuxDebugLog(
            "terminal.dropOverlay event=\(event) surface=\(surface) zone=\(zoneText) " +
            "hidden=\(dropZoneOverlayView.isHidden ? 1 : 0) bounds=\(boundsText) frame=\(frameText) " +
            "overlaySuper=\(overlaySuperviewClass) overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "scrollOrigin=\(scrollOriginText) surfaceOrigin=\(surfaceOriginText)"
        )
    }
#endif

#if DEBUG
    @discardableResult
    func debugSimulateFileDrop(paths: [String], asImageData: Bool = false) -> Bool {
        surfaceView.debugSimulateFileDrop(paths: paths, asImageData: asImageData)
    }

    func debugPendingSurfaceSize() -> CGSize? {
        surfaceView.debugPendingSurfaceSize()
    }

    func debugInactiveOverlayState() -> (isHidden: Bool, alpha: CGFloat) {
        (
            inactiveOverlayView.isHidden,
            inactiveOverlayView.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0
        )
    }

    struct DebugDropZoneOverlayState {
        let isHidden: Bool
        let frame: CGRect
        let isAttachedToHostedView: Bool
        let isAttachedToParentContainer: Bool
    }

    func debugDropZoneOverlayState() -> DebugDropZoneOverlayState {
        DebugDropZoneOverlayState(
            isHidden: dropZoneOverlayView.isHidden,
            frame: dropZoneOverlayView.frame,
            isAttachedToHostedView: dropZoneOverlayView.superview === self,
            isAttachedToParentContainer: dropZoneOverlayView.superview === superview
        )
    }

    func debugHasSearchOverlay() -> Bool {
        guard let overlay = searchOverlayHostingView else { return false }
        return overlay.superview === self && !overlay.isHidden
    }

    func debugSearchOverlayHostingViewForTesting() -> NSView? {
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self else {
            return nil
        }
        return overlay
    }

    func debugSurfaceHasPendingLeftMouseReleaseForTesting() -> Bool {
        surfaceView.debugHasPendingLeftMouseReleaseForTesting()
    }

    func debugHasKeyboardCopyModeIndicator() -> Bool {
        keyboardCopyModeBadgeContainerView.superview === self && !keyboardCopyModeBadgeContainerView.isHidden
    }

#endif

    /// Handle file/URL drops, forwarding to the terminal as shell-escaped paths.
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        #if DEBUG
        cmuxDebugLog("terminal.swiftUIDrop surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") urls=\(urls.map(\.lastPathComponent))")
        #endif
        return surfaceView.handleDroppedFileURLs(urls)
    }

    func terminalViewForDrop(at point: NSPoint) -> GhosttyNSView? {
        guard bounds.contains(point), !isHidden else { return nil }
        return surfaceView
    }

}
