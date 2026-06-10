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


// MARK: - Geometry and content synchronization
extension GhosttySurfaceScrollView {
    override func layout() {
        super.layout()
        synchronizeGeometryAndContent()
        _ = setFrameIfNeeded(paneDropTargetView, to: bounds)
        bringPaneDropTargetToFrontIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard activeDropZone != nil || pendingDropZone != nil else { return }
        attachDropZoneOverlayIfNeeded()
        if let zone = activeDropZone ?? pendingDropZone {
            applyDropZoneOverlayFrame(dropZoneOverlayFrame(for: zone, in: bounds.size))
        }
    }

    /// Reconcile AppKit geometry with ghostty surface geometry synchronously.
    /// Used after split topology mutations (close/split) to prevent a stale one-frame
    /// IOSurface size from being presented after pane expansion.
    @discardableResult
    func reconcileGeometryNow() -> Bool {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileGeometryNow()
            }
            return false
        }

        return synchronizeGeometryAndContent()
    }

    /// Request an immediate terminal redraw after geometry updates so stale IOSurface
    /// contents do not remain stretched during live resize churn.
    func refreshSurfaceNow(reason: String = "portal.refreshSurfaceNow") {
        // Portal reparent/reveal can settle geometry a tick before AppKit finishes
        // realizing the terminal subtree's backing layer state. Flush display for the
        // hosted subtree first so forceRefresh does not race a still-unrealized layer.
        layoutSubtreeIfNeeded()
        surfaceView.layoutSubtreeIfNeeded()
        displayIfNeeded()
        surfaceView.displayIfNeeded()
        surfaceView.terminalSurface?.forceRefresh(reason: reason)
    }

    @discardableResult
    func synchronizeGeometryAndContent() -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let didScrollbarAppearanceChange = synchronizeScrollbarAppearance()
        let previousSurfaceSize = surfaceView.frame.size
        if let sharedBackdropCutoutView {
            _ = setFrameIfNeeded(sharedBackdropCutoutView, to: bounds)
        }
        _ = setFrameIfNeeded(backgroundView, to: bounds)
        _ = setFrameIfNeeded(scrollView, to: bounds)
        let targetSize = scrollView.bounds.size
#if DEBUG
        logLayoutDuringActiveDrag(targetSize: targetSize)
#endif
        let targetSurfaceFrame = CGRect(origin: surfaceView.frame.origin, size: targetSize)
        _ = setFrameIfNeeded(surfaceView, to: targetSurfaceFrame)
        let targetDocumentFrame = CGRect(
            origin: documentView.frame.origin,
            size: CGSize(width: scrollView.bounds.width, height: documentView.frame.height)
        )
        _ = setFrameIfNeeded(documentView, to: targetDocumentFrame)
        _ = setFrameIfNeeded(mobileViewportBorderOverlayView, to: bounds)
        _ = setFrameIfNeeded(inactiveOverlayView, to: bounds)
        _ = setFrameIfNeeded(paneDropTargetView, to: bounds)
        if let zone = activeDropZone {
            attachDropZoneOverlayIfNeeded()
            _ = setFrameIfNeeded(
                dropZoneOverlayView,
                to: dropZoneOverlayFrame(for: zone, in: bounds.size)
            )
        }
        if let pending = pendingDropZone,
           bounds.width > 2,
           bounds.height > 2 {
            pendingDropZone = nil
#if DEBUG
            let frame = dropZoneOverlayFrame(for: pending, in: bounds.size)
            logDropZoneOverlay(event: "flushPending", zone: pending, frame: frame)
#endif
            // Reuse the normal show/update path so deferred overlays get the
            // same initial animation as direct drop-zone activation.
            setDropZoneOverlay(zone: pending)
        }
        _ = setFrameIfNeeded(notificationRingOverlayView, to: bounds)
        _ = setFrameIfNeeded(flashOverlayView, to: bounds)
        if let overlay = searchOverlayHostingView {
            _ = setFrameIfNeeded(overlay, to: bounds)
        }
        bringPaneDropTargetToFrontIfNeeded()
        // NSScrollView can defer clip-view/content-size updates until its own layout pass,
        // which makes interactive width changes arrive a queue turn late on Sequoia.
        if didScrollbarAppearanceChange {
            scrollView.tile()
        }
        scrollView.layoutSubtreeIfNeeded()
        updateNotificationRingPath()
        updateFlashPath(style: lastFlashStyle)
        updateFlashAppearance(style: lastFlashStyle)
        synchronizeScrollView()
        synchronizeSurfaceView()
        let didCoreSurfaceChange = synchronizeCoreSurface()
        return !sizeApproximatelyEqual(previousSurfaceSize, targetSize) || didCoreSurfaceChange
    }

    func setMobileViewportBorder(size: CGSize?, drawRight: Bool, drawBottom: Bool) {
        let isVisible = drawRight || drawBottom
        mobileViewportBorderOverlayView.effectiveSize = size
        mobileViewportBorderOverlayView.drawsVisibleAreaBorder = isVisible
        mobileViewportBorderOverlayView.drawsVisibleAreaRightBorder = drawRight
        mobileViewportBorderOverlayView.drawsVisibleAreaBottomBorder = drawBottom
        mobileViewportBorderOverlayView.isHidden = !isVisible
    }

    @discardableResult
    func setFrameIfNeeded(_ view: NSView, to frame: CGRect) -> Bool {
        guard !Self.rectApproximatelyEqual(view.frame, frame) else { return false }
        view.frame = frame
        return true
    }

    private func sizeApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon && abs(lhs.height - rhs.height) <= epsilon
    }

    func pointApproximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        guard let window else { return }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive, self.surfaceView.isVisibleInUI, let tabId = self.surfaceView.tabId, let surfaceId = self.surfaceView.terminalSurface?.id, self.matchesCurrentTerminalFocusTarget(tabId: tabId, surfaceId: surfaceId) else { return }
#if DEBUG
            cmuxDebugLog("find.window.didBecomeKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(self.surfaceView.terminalSurface?.searchState != nil) focusTarget=\(self.searchFocusTarget) firstResponder=\(String(describing: self.window?.firstResponder))")
#endif
            self.scheduleAutomaticFirstResponderApply(reason: "didBecomeKey")
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            let searchActive = self.surfaceView.terminalSurface?.searchState != nil
            // Losing key window does not always trigger first-responder resignation, so force
            // the focused terminal view to yield responder to keep Ghostty cursor/focus state in sync.
            if let fr = window.firstResponder as? NSView,
               fr === self.surfaceView || fr.isDescendant(of: self.surfaceView) {
#if DEBUG
                cmuxDebugLog("find.window.didResignKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(searchActive) resigningFirstResponder")
#endif
                window.makeFirstResponder(nil)
            } else {
#if DEBUG
                cmuxDebugLog("find.window.didResignKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(searchActive) firstResponder=\(String(describing: window.firstResponder)) (not terminal, skipping)")
#endif
            }
        })
        if window.isKeyWindow {
            scheduleAutomaticFirstResponderApply(reason: "viewDidMoveToWindow")
        }
    }

    /// Applies the host-layer terminal fill and optionally clears the shared backdrop behind it.
    func setBackgroundColor(_ color: NSColor, clearsSharedWindowBackdrop: Bool = false) {
        guard let layer = backgroundView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        synchronizeSharedBackdropCutout(visible: clearsSharedWindowBackdrop)
        layer.backgroundColor = color.cgColor
        layer.isOpaque = color.alphaComponent >= 1.0
        CATransaction.commit()
        // The viewport border strokes the window-chrome separator color, which tracks the
        // terminal background/theme. Repaint it when the background changes (e.g. theme
        // switch) so a connected iOS device's visible-area border stays in sync.
        if !mobileViewportBorderOverlayView.isHidden {
            mobileViewportBorderOverlayView.needsDisplay = true
        }
    }

    /// Keeps the shared-backdrop cutout view present only while a pane-local fill needs it.
    private func synchronizeSharedBackdropCutout(visible: Bool) {
        if visible {
            let cutoutView = sharedBackdropCutoutView ?? makeSharedBackdropCutoutView()
            _ = setFrameIfNeeded(cutoutView, to: bounds)
            return
        }

        sharedBackdropCutoutView?.removeFromSuperview()
        sharedBackdropCutoutView = nil
    }

    /// Creates the Core Image filtered view that subtracts pane-local fills from shared backdrop.
    ///
    /// AppKit requires `layerUsesCoreImageFilters` to be configured before display, so the
    /// cutout view is created lazily only when a pane-local OSC background override needs it.
    private func makeSharedBackdropCutoutView() -> NSView {
        let sharedBackdropCutoutFilter = TerminalSharedBackdropCutoutFilter()
        sharedBackdropCutoutFilter.name = "terminalSharedBackdropCutout"
        let cutoutView = NSView(frame: bounds)
        cutoutView.wantsLayer = true
        cutoutView.layerUsesCoreImageFilters = true
        cutoutView.compositingFilter = sharedBackdropCutoutFilter
        cutoutView.layer?.backgroundColor = NSColor.white.cgColor
        cutoutView.layer?.isOpaque = true
        addSubview(cutoutView, positioned: .below, relativeTo: backgroundView)
        sharedBackdropCutoutView = cutoutView
        return cutoutView
    }

    func refreshHostBackgroundAfterGhosttyConfigReload() {
        _ = synchronizeGeometryAndContent()
        surfaceView.applySurfaceBackground()
        surfaceView.applyWindowBackgroundIfActive()
    }

    func reapplySurfaceColorSchemeAfterGhosttyConfigReload(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        surfaceView.applySurfaceColorScheme(
            force: true,
            preferredColorScheme: preferredColorScheme
        )
    }

    func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        guard !pointApproximatelyEqual(surfaceView.frame.origin, visibleRect.origin) else { return }
#if DEBUG
        logDragGeometryChange(event: "surfaceOrigin", old: surfaceView.frame.origin, new: visibleRect.origin)
#endif
        surfaceView.frame.origin = visibleRect.origin
    }

    /// Match upstream Ghostty behavior: use content area width (excluding non-content
    /// regions such as scrollbar space) when telling libghostty the terminal size.
    @discardableResult
    func synchronizeCoreSurface() -> Bool {
        let width = max(0, surfaceView.frame.width)
        let height = surfaceView.frame.height
        guard width > 0, height > 0 else { return false }
        return surfaceView.pushTargetSurfaceSize(CGSize(width: width, height: height))
    }

}
