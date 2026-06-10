import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


// MARK: - Geometry observers & external geometry sync
extension WindowBrowserPortal {
    private static func dividerHitRectContains(_ point: NSPoint, rect: NSRect) -> Bool {
        point.x >= rect.minX &&
            point.x <= rect.maxX &&
            point.y >= rect.minY &&
            point.y <= rect.maxY
    }

    static func shouldTreatSplitResizeAsExternalGeometry(
        _ splitView: NSSplitView,
        window: NSWindow,
        hostView: WindowBrowserHostView
    ) -> Bool {
        guard splitView.window === window else { return false }
        // WebKit's attached DevTools uses internal NSSplitView instances for the
        // side/bottom inspector layout. Those resizes are local to hosted content
        // and should not trigger a full portal re-sync/refresh pass.
        guard !splitView.isDescendant(of: hostView) else { return false }
        // Browser host anchors already emit coalesced geometry callbacks while the
        // user drags a split divider. Running the portal-wide external-geometry
        // sync on the same drag frame doubles up WebKit refresh work and shows up
        // as visible flicker in browser panes.
        return !isInteractiveSplitDividerDrag(in: window)
    }

    private static func noteInteractiveSplitDividerDragIfNeeded(
        _ splitView: NSSplitView,
        window: NSWindow,
        hostView: WindowBrowserHostView
    ) {
        guard splitView.window === window else { return }
        guard !splitView.isDescendant(of: hostView) else { return }
        guard (NSEvent.pressedMouseButtons & 1) != 0 else { return }
        guard let event = NSApp.currentEvent else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - event.timestamp) < 0.1 else { return }
        guard event.window === window else { return }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            break
        default:
            return
        }
        guard splitView.arrangedSubviews.count >= 2 else { return }

        let location = splitView.convert(event.locationInWindow, from: nil)
        let first = splitView.arrangedSubviews[0].frame
        let second = splitView.arrangedSubviews[1].frame
        let thickness = splitView.dividerThickness
        let dividerRect: NSRect

        if splitView.isVertical {
            guard first.width > 1, second.width > 1 else { return }
            dividerRect = NSRect(
                x: max(0, first.maxX),
                y: 0,
                width: thickness,
                height: splitView.bounds.height
            )
        } else {
            guard first.height > 1, second.height > 1 else { return }
            dividerRect = NSRect(
                x: 0,
                y: max(0, first.maxY),
                width: splitView.bounds.width,
                height: thickness
            )
        }

        let hitRect = dividerRect.insetBy(dx: -5, dy: -5)
        if dividerHitRectContains(location, rect: hitRect) {
            window.browserPortalHasInteractiveSplitDividerDrag = true
        }
    }

    private static func isInteractiveSplitDividerDrag(in window: NSWindow) -> Bool {
        if window.browserPortalHasInteractiveSplitDividerDrag {
            return true
        }
        guard (NSEvent.pressedMouseButtons & 1) != 0 else { return false }
        guard let event = NSApp.currentEvent else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - event.timestamp) < 0.1 else { return false }
        guard event.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            return true
        default:
            return false
        }
    }

    func installGeometryObservers(for window: NSWindow) {
        guard geometryObservers.isEmpty else { return }

        let center = NotificationCenter.default
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSSplitView.willResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window else { return }
                Self.noteInteractiveSplitDividerDragIfNeeded(
                    splitView,
                    window: window,
                    hostView: self.hostView
                )
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window,
                      Self.shouldTreatSplitResizeAsExternalGeometry(
                          splitView,
                          window: window,
                          hostView: self.hostView
                      ) else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
    }

    func removeGeometryObservers() {
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
    }

    func scheduleExternalGeometrySynchronize() {
        guard !hasExternalGeometrySyncScheduled else { return }
        hasExternalGeometrySyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasExternalGeometrySyncScheduled = false
            self.synchronizeAllEntriesFromExternalGeometryChange()
        }
    }

    private func synchronizeAllEntriesFromExternalGeometryChange() {
        guard ensureInstalled() else { return }
        installedContainerView?.layoutSubtreeIfNeeded()
        installedReferenceView?.layoutSubtreeIfNeeded()
        hostView.superview?.layoutSubtreeIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        synchronizeAllWebViews(excluding: nil, source: "externalGeometry")

        for entry in entriesByWebViewId.values {
            guard let webView = entry.webView,
                  let containerView = entry.containerView,
                  !containerView.isHidden else { continue }
            guard webView.superview === containerView else { continue }
            invalidateHostedWebViewGeometry(
                webView,
                in: containerView,
                reason: "externalGeometry"
            )
        }
    }

}
