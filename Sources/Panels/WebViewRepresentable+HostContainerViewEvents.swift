import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - NSView Lifecycle, Layout & Mouse Overrides
extension WebViewRepresentable.HostContainerView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                notifyHostedWebKitHidden(reason: "viewDidMoveToWindow")
                clearActiveDividerCursor(restoreArrow: false)
            } else {
                scheduleHostedInspectorDividerReapply(reason: "viewDidMoveToWindow")
                scheduleHostedInspectorDockConfigurationSync(reason: "viewDidMoveToWindow")
                refreshHostedWebKitPresentation(
                    reason: "viewDidMoveToWindow",
                    forceLifecycleRefresh: hostedInspectorFrontendWebView != nil
                )
            }
            window?.invalidateCursorRects(for: self)
            onDidMoveToWindow?()
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "viewDidMoveToWindow")
#endif
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleHostedInspectorDividerReapply(reason: "viewDidMoveToSuperview")
            scheduleHostedInspectorDockConfigurationSync(reason: "viewDidMoveToSuperview")
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "viewDidMoveToSuperview")
#endif
        }

        override func layout() {
            super.layout()
            _ = promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
            if enforceAdaptiveBottomDockIfNeeded(reason: "host.layout") {
                updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout")
                notifyGeometryChangedIfNeeded()
#if DEBUG
                debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
                return
            }
            if let previousSize = lastHostedInspectorLayoutBoundsSize,
               Self.sizeApproximatelyEqual(previousSize, bounds.size, epsilon: 0.5) {
                // Origin-only frame churn is common while the surrounding split layout
                // settles. Reapplying the side-docked inspector at the same size fights
                // WebKit's own dock layout and shows up as visible flicker.
                if !isHostedInspectorDividerDragActive {
                    if hasStoredHostedInspectorWidthPreference {
                        reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "host.layout.sameSize")
                    } else if !isHostedInspectorSideDockActive() {
                        captureHostedInspectorPreferredWidthFromCurrentLayout(reason: "host.layout.sameSize")
                    }
                }
                updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout.sameSize")
                notifyGeometryChangedIfNeeded()
#if DEBUG
                debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
                return
            }
            lastHostedInspectorLayoutBoundsSize = bounds.size
            if isHostedInspectorSideDockActive() {
                layoutHostedInspectorSideDockIfNeeded(reason: "host.layout.sideDock")
            } else if hasStoredHostedInspectorWidthPreference {
                reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "host.layout")
            } else {
                captureHostedInspectorPreferredWidthFromCurrentLayout(reason: "host.layout")
            }
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "host.layout")
            scheduleHostedInspectorDockConfigurationSync(reason: "layout")
            notifyGeometryChangedIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "layout")
#endif
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            window?.invalidateCursorRects(for: self)
            // Mark dirty; the callback fires from layout() with the settled geometry.
            markGeometryDirtyIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "setFrameOrigin")
#endif
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
            // Mark dirty; the callback fires from layout() with the settled geometry.
            markGeometryDirtyIfNeeded()
#if DEBUG
            debugLogHostedInspectorLayoutIfNeeded(reason: "setFrameSize")
#endif
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard let hostedInspectorHit = hostedInspectorDividerCandidate() else { return }
            let clipped = hostedInspectorDividerHitRect(for: hostedInspectorHit).intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
            addCursorRect(clipped, cursor: NSCursor.resizeLeftRight)
        }

        override func updateTrackingAreas() {
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let options: NSTrackingArea.Options = [
                .inVisibleRect,
                .activeAlways,
                .cursorUpdate,
                .mouseMoved,
                .mouseEnteredAndExited,
                .enabledDuringMouseDrag,
            ]
            let next = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(next)
            trackingArea = next
            super.updateTrackingAreas()
        }

        override func cursorUpdate(with event: NSEvent) {
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            clearActiveDividerCursor(restoreArrow: true)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hostedInspectorHit = hostedInspectorDividerHit(at: point)
            updateDividerCursor(at: point, hostedInspectorHit: hostedInspectorHit)
            let passThrough = shouldPassThroughToSidebarResizer(at: point, hostedInspectorHit: hostedInspectorHit)
            if passThrough {
#if DEBUG
                debugLogHitTest(stage: "hitTest.pass", point: point, passThrough: true, hitView: nil)
#endif
                return nil
            }
            if let hostedInspectorHit {
                if let nativeHit = nativeHostedInspectorHit(at: point, hostedInspectorHit: hostedInspectorHit) {
#if DEBUG
                    debugLogHitTest(stage: "hitTest.hostedInspectorNative", point: point, passThrough: false, hitView: nativeHit)
#endif
                    if nativeHit !== hostedInspectorHit.inspectorView &&
                        !hostedInspectorHit.inspectorView.isDescendant(of: nativeHit) {
                        return nativeHit
                    }
                }
#if DEBUG
                debugLogHitTest(
                    stage: "hitTest.hostedInspectorManual",
                    point: point,
                    passThrough: false,
                    hitView: self
                )
#endif
                return self
            }
            let hit = super.hitTest(point)
#if DEBUG
            debugLogHitTest(stage: "hitTest.result", point: point, passThrough: false, hitView: hit)
#endif
            return hit
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let hostedInspectorHit = hostedInspectorDividerHit(at: point) else {
                super.mouseDown(with: event)
                return
            }

            hostedInspectorReapplyWorkItem?.cancel()
            isHostedInspectorDividerDragActive = true
            hostedInspectorDividerDrag = HostedInspectorDividerDragState(
                containerView: hostedInspectorHit.containerView,
                pageView: hostedInspectorHit.pageView,
                inspectorView: hostedInspectorHit.inspectorView,
                dockSide: hostedInspectorHit.dockSide,
                initialWindowX: event.locationInWindow.x,
                initialPageFrame: hostedInspectorHit.pageView.frame,
                initialInspectorFrame: hostedInspectorHit.inspectorView.frame
            )
#if DEBUG
            debugLogHostedInspectorFrames(stage: "drag.start", point: point, hit: hostedInspectorHit)
#endif
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragState = hostedInspectorDividerDrag else {
                super.mouseDragged(with: event)
                return
            }

            let containerBounds = dragState.containerView.bounds
            let minimumInspectorWidth = Self.minimumHostedInspectorWidth
            let initialDividerX = dragState.dockSide.dividerX(
                pageFrame: dragState.initialPageFrame,
                inspectorFrame: dragState.initialInspectorFrame
            )
            let proposedDividerX = initialDividerX + (event.locationInWindow.x - dragState.initialWindowX)
            let clampedDividerX = dragState.dockSide.clampedDividerX(
                proposedDividerX,
                containerBounds: containerBounds,
                pageFrame: dragState.initialPageFrame,
                minimumInspectorWidth: minimumInspectorWidth
            )
            let inspectorWidth = dragState.dockSide.inspectorWidth(
                forDividerX: clampedDividerX,
                in: containerBounds
            )
            recordPreferredHostedInspectorWidth(inspectorWidth, containerBounds: containerBounds)
            _ = applyHostedInspectorDividerWidth(
                inspectorWidth,
                to: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                ),
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: "drag"
            )
#if DEBUG
            debugLogHostedInspectorFrames(
                stage: "drag.update",
                point: convert(event.locationInWindow, from: nil),
                hit: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                )
            )
#endif
            updateDividerCursor(
                at: convert(event.locationInWindow, from: nil),
                hostedInspectorHit: HostedInspectorDividerHit(
                    containerView: dragState.containerView,
                    pageView: dragState.pageView,
                    inspectorView: dragState.inspectorView,
                    dockSide: dragState.dockSide
                )
            )
        }

        override func mouseUp(with event: NSEvent) {
            let finalDragState = hostedInspectorDividerDrag
            hostedInspectorDividerDrag = nil
            isHostedInspectorDividerDragActive = false
            updateDividerCursor(at: convert(event.locationInWindow, from: nil))
            if let finalDragState {
#if DEBUG
                debugLogHostedInspectorFrames(
                    stage: "drag.end",
                    point: convert(event.locationInWindow, from: nil),
                    hit: HostedInspectorDividerHit(
                        containerView: finalDragState.containerView,
                        pageView: finalDragState.pageView,
                        inspectorView: finalDragState.inspectorView,
                        dockSide: finalDragState.dockSide
                    )
                )
#endif
                reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: "drag.end")
            }
            super.mouseUp(with: event)
        }

}
