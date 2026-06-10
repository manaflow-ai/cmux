import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif


// MARK: - Geometry observers and external geometry synchronization
extension WindowTerminalPortal {
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
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let splitView = notification.object as? NSSplitView,
                      let window = self.window,
                      splitView.window === window else { return }
                self.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
            }
        })
        geometryObservers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: hostView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalGeometrySynchronize()
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
        scheduleExternalGeometrySynchronize(forceImmediate: true)
    }

    func scheduleExternalGeometrySynchronize(forceImmediate: Bool) {
        // Coalesce to the latest request so ancestor/frame churn (for example
        // sidebar toggles) doesn't resize the PTY at stale intermediate widths.
        externalGeometrySyncGeneration &+= 1
        let generation = externalGeometrySyncGeneration
        guard !hasExternalGeometrySyncScheduled else {
            pendingExternalGeometrySyncRequiresImmediate =
                pendingExternalGeometrySyncRequiresImmediate || forceImmediate
            return
        }
        hasExternalGeometrySyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let performSync = {
                var shouldFlushLatestNow = forceImmediate
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = self.pendingExternalGeometrySyncRequiresImmediate
                }
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = self.hostView.inLiveResize
                }
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = self.window?.inLiveResize == true
                }
                if !shouldFlushLatestNow {
                    shouldFlushLatestNow = TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive
                }
                // During sidebar/split drags, new geometry requests can arrive
                // faster than this queued sync runs. Flush the latest visible
                // frame instead of rescheduling behind the drag stream.
                if self.externalGeometrySyncGeneration != generation, !shouldFlushLatestNow {
                    self.hasExternalGeometrySyncScheduled = false
                    let followUpRequiresImmediate = self.pendingExternalGeometrySyncRequiresImmediate
                    self.pendingExternalGeometrySyncRequiresImmediate = false
                    self.scheduleExternalGeometrySynchronize(forceImmediate: followUpRequiresImmediate)
                    return
                }
                self.hasExternalGeometrySyncScheduled = false
                self.pendingExternalGeometrySyncRequiresImmediate = false
                self.synchronizeAllEntriesFromExternalGeometryChange()
            }
            var shouldPerformNow = forceImmediate
            if !shouldPerformNow {
                shouldPerformNow = self.pendingExternalGeometrySyncRequiresImmediate
            }
            if !shouldPerformNow {
                shouldPerformNow = self.hostView.inLiveResize
            }
            if !shouldPerformNow {
                shouldPerformNow = self.window?.inLiveResize == true
            }
            if !shouldPerformNow {
                shouldPerformNow = TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive
            }
            if shouldPerformNow {
                performSync()
            } else {
                DispatchQueue.main.async(execute: performSync)
            }
        }
    }

    func synchronizeLayoutHierarchy() {
        installedContainerView?.layoutSubtreeIfNeeded()
        installedReferenceView?.layoutSubtreeIfNeeded()
        hostView.superview?.layoutSubtreeIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        _ = synchronizeHostFrameToReference()
    }

    @discardableResult
    func synchronizeHostFrameToReference() -> Bool {
        guard let container = installedContainerView,
              let reference = installedReferenceView else {
            return false
        }
        let frameInContainer = container.convert(reference.bounds, from: reference)
        let hasFiniteFrame =
            frameInContainer.origin.x.isFinite &&
            frameInContainer.origin.y.isFinite &&
            frameInContainer.size.width.isFinite &&
            frameInContainer.size.height.isFinite
        guard hasFiniteFrame else { return false }

        if !Self.rectApproximatelyEqual(hostView.frame, frameInContainer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostView.frame = frameInContainer
            CATransaction.commit()
#if DEBUG
            cmuxDebugLog(
                "portal.hostFrame.update host=\(portalDebugToken(hostView)) " +
                "frame=\(portalDebugFrame(frameInContainer))"
            )
#endif
        }
        return frameInContainer.width > 1 && frameInContainer.height > 1
    }

    func synchronizeAllEntriesFromExternalGeometryChange() {
        guard ensureInstalled() else { return }
        synchronizeLayoutHierarchy()
        synchronizeAllHostedViews(excluding: nil)
        reconcileVisibleHostedViewsAfterGeometrySync(reason: "portal.externalGeometrySync")
    }

}
