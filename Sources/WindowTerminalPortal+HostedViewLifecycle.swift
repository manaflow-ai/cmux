import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif


// MARK: - Hosted view binding, synchronization, and entry lifecycle
extension WindowTerminalPortal {
    func detachHostedView(withId hostedId: ObjectIdentifier) {
        guard let entry = entriesByHostedId.removeValue(forKey: hostedId) else { return }
        if let anchor = entry.anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }
#if DEBUG
        let hadSuperview = (entry.hostedView?.superview === hostView) ? 1 : 0
        cmuxDebugLog(
            "portal.detach hosted=\(portalDebugToken(entry.hostedView)) " +
            "anchor=\(portalDebugToken(entry.anchorView)) hadSuperview=\(hadSuperview)"
        )
#endif
        if let hostedView = entry.hostedView, hostedView.superview === hostView {
            hostedView.removeFromSuperview()
        }
    }

    /// Hide a portal entry without detaching it. Updates visibleInUI to false and
    /// sets isHidden = true so subsequent synchronizeHostedView calls keep it hidden.
    /// Used when a workspace is permanently unmounted (vs. transient bonsplit dismantles).
    func hideEntry(forHostedId hostedId: ObjectIdentifier) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        entry.visibleInUI = false
        entry.transientRecoveryRetriesRemaining = 0
        entriesByHostedId[hostedId] = entry
        entry.hostedView?.isHidden = true
#if DEBUG
        cmuxDebugLog("portal.hideEntry hosted=\(portalDebugToken(entry.hostedView)) reason=workspaceUnmount")
#endif
    }

    /// Update the visibleInUI flag on an existing entry without rebinding.
    /// Used when a deferred bind is pending — this ensures synchronizeHostedView
    /// won't hide a view that updateNSView has already marked as visible.
    func updateEntryVisibility(forHostedId hostedId: ObjectIdentifier, visibleInUI: Bool) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        entry.visibleInUI = visibleInUI
        if !visibleInUI {
            entry.transientRecoveryRetriesRemaining = 0
        }
        entriesByHostedId[hostedId] = entry
    }

    func isHostedViewBoundToAnchor(withId hostedId: ObjectIdentifier, anchorView: NSView) -> Bool {
        guard let entry = entriesByHostedId[hostedId],
              let boundAnchor = entry.anchorView else { return false }
        return boundAnchor === anchorView
    }

    func bind(
        hostedView: GhosttySurfaceScrollView,
        to anchorView: NSView,
        visibleInUI: Bool,
        zPriority: Int = 0,
        deferLayoutSynchronization: Bool = false
    ) {
        guard ensureInstalled(syncLayout: !deferLayoutSynchronization) else { return }

        let hostedId = ObjectIdentifier(hostedView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByHostedId[hostedId]

        if let previousHostedId = hostedByAnchorId[anchorId], previousHostedId != hostedId {
#if DEBUG
            let previousToken = entriesByHostedId[previousHostedId]
                .map { portalDebugToken($0.hostedView) }
                ?? String(describing: previousHostedId)
            cmuxDebugLog(
                "portal.bind.replace anchor=\(portalDebugToken(anchorView)) " +
                "oldHosted=\(previousToken) newHosted=\(portalDebugToken(hostedView))"
            )
#endif
            detachHostedView(withId: previousHostedId)
        }

        if let oldEntry = entriesByHostedId[hostedId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(oldAnchor))
        }

        hostedByAnchorId[anchorId] = hostedId
        entriesByHostedId[hostedId] = Entry(
            hostedView: hostedView,
            anchorView: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority,
            transientRecoveryRetriesRemaining: 0
        )

        let didChangeAnchor: Bool = {
            guard let previousAnchor = previousEntry?.anchorView else { return true }
            return previousAnchor !== anchorView
        }()
        let becameVisible = (previousEntry?.visibleInUI ?? false) == false && visibleInUI
        let priorityIncreased = zPriority > (previousEntry?.zPriority ?? Int.min)
#if DEBUG
        if previousEntry == nil || didChangeAnchor || becameVisible || priorityIncreased || hostedView.superview !== hostView {
            cmuxDebugLog(
                "portal.bind hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) prevAnchor=\(portalDebugToken(previousEntry?.anchorView)) " +
                "visible=\(visibleInUI ? 1 : 0) prevVisible=\((previousEntry?.visibleInUI ?? false) ? 1 : 0) " +
                "z=\(zPriority) prevZ=\(previousEntry?.zPriority ?? Int.min)"
            )
        }
#endif

        _ = synchronizeHostFrameToReference()

        // Seed frame/bounds before entering the window so a freshly reparented
        // surface doesn't do a transient 800x600 size update on viewDidMoveToWindow.
        if let seededFrame = seededFrameInHost(for: anchorView),
           seededFrame.width > 0,
           seededFrame.height > 0 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = seededFrame
            hostedView.bounds = NSRect(origin: .zero, size: seededFrame.size)
            CATransaction.commit()
        } else {
            // If anchor geometry is still unsettled, keep this hidden/zero-sized until
            // synchronizeHostedView resolves a valid target frame on the next layout tick.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = .zero
            hostedView.bounds = .zero
            CATransaction.commit()
            hostedView.isHidden = true
        }
        // Keep inner scroll/surface geometry in sync with the seeded outer frame
        // before the hosted view enters a window.
        hostedView.reconcileGeometryNow()

        if hostedView.superview !== hostView {
#if DEBUG
            cmuxDebugLog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) " +
                "reason=attach super=\(portalDebugToken(hostedView.superview))"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        } else if (becameVisible || priorityIncreased), hostView.subviews.last !== hostedView {
            // Refresh z-order only when a view becomes visible or gets a higher priority.
            // Anchor-only churn is common during split tree updates; forcing remove/add there
            // causes transient inWindow=0 -> 1 bounces that can flash black.
#if DEBUG
            cmuxDebugLog(
                "portal.reparent hosted=\(portalDebugToken(hostedView)) reason=raise " +
                "didChangeAnchor=\(didChangeAnchor ? 1 : 0) becameVisible=\(becameVisible ? 1 : 0) " +
                "priorityIncreased=\(priorityIncreased ? 1 : 0)"
            )
#endif
            hostView.addSubview(hostedView, positioned: .above, relativeTo: nil)
        }

        ensureDividerOverlayOnTop()

        if deferLayoutSynchronization {
            // Bind calls from SwiftUI NSViewRepresentable update/layout callbacks
            // must not force ancestor layout synchronously. Still reconcile the
            // portal entry from already-current host geometry so resize/visibility
            // does not lag until a later external observer turn.
            synchronizeHostedView(withId: hostedId, syncLayout: false)
            scheduleDeferredFullSynchronizeAll()
        } else {
            synchronizeHostedView(withId: hostedId)
            scheduleDeferredFullSynchronizeAll()
        }
        pruneDeadEntries()
    }

    func synchronizeHostedViewForAnchor(_ anchorView: NSView, syncLayout: Bool = true) {
        guard ensureInstalled(syncLayout: syncLayout) else { return }
        if syncLayout {
            synchronizeLayoutHierarchy()
        } else {
            _ = synchronizeHostFrameToReference()
        }
        pruneDeadEntries()
        let anchorId = ObjectIdentifier(anchorView)
        let primaryHostedId = hostedByAnchorId[anchorId]
        if let primaryHostedId {
            synchronizeHostedView(withId: primaryHostedId, syncLayout: syncLayout)
        }

        // Failsafe: during aggressive divider drags/structural churn, one anchor can miss a
        // geometry callback while another fires. Reconcile all mapped hosted views so no stale
        // frame remains "stuck" onscreen until the next interaction.
        synchronizeAllHostedViews(excluding: primaryHostedId, syncLayout: syncLayout)
        reconcileVisibleHostedViewsAfterGeometrySync(reason: "portal.anchorGeometrySync")
        scheduleDeferredFullSynchronizeAll()
    }

    func reconcileVisibleHostedViewsAfterGeometrySync(reason: String) {
        // During live resize, AppKit can deliver frame churn where outer portal geometry
        // settles a tick before the terminal's own scroll/surface hierarchy. Only force an
        // in-place surface refresh when reconciliation actually changed terminal geometry.
        for entry in entriesByHostedId.values {
            guard let hostedView = entry.hostedView, !hostedView.isHidden else { continue }
            if hostedView.reconcileGeometryNow() {
                hostedView.refreshSurfaceNow(reason: reason)
            }
        }
    }

    private func scheduleDeferredFullSynchronizeAll() {
        guard !hasDeferredFullSyncScheduled else { return }
        hasDeferredFullSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasDeferredFullSyncScheduled = false
            self.synchronizeAllHostedViews(excluding: nil)
        }
    }

    func synchronizeAllHostedViews(excluding hostedIdToSkip: ObjectIdentifier?, syncLayout: Bool = true) {
        guard ensureInstalled(syncLayout: syncLayout) else { return }
        if syncLayout {
            synchronizeLayoutHierarchy()
        } else {
            _ = synchronizeHostFrameToReference()
        }
        pruneDeadEntries()
        let hostedIds = Array(entriesByHostedId.keys)
        for hostedId in hostedIds {
            if hostedId == hostedIdToSkip { continue }
            synchronizeHostedView(withId: hostedId, syncLayout: syncLayout)
        }
    }

    private func resetTransientRecoveryRetryIfNeeded(forHostedId hostedId: ObjectIdentifier, entry: inout Entry) {
        guard entry.transientRecoveryRetriesRemaining != 0 else { return }
        entry.transientRecoveryRetriesRemaining = 0
        entriesByHostedId[hostedId] = entry
    }

    private func scheduleTransientRecoveryRetryIfNeeded(
        forHostedId hostedId: ObjectIdentifier,
        entry: inout Entry,
        hostedView: GhosttySurfaceScrollView,
        reason: String
    ) -> Bool {
        guard Self.transientRecoveryEnabled else { return false }
        if entry.transientRecoveryRetriesRemaining == 0 {
            entry.transientRecoveryRetriesRemaining = Self.transientRecoveryRetryBudget
        }
        guard entry.transientRecoveryRetriesRemaining > 0 else { return false }

        entry.transientRecoveryRetriesRemaining -= 1
        entriesByHostedId[hostedId] = entry
#if DEBUG
        cmuxDebugLog(
            "portal.sync.deferRecover hosted=\(portalDebugToken(hostedView)) " +
            "reason=\(reason) remaining=\(entry.transientRecoveryRetriesRemaining)"
        )
#endif
        if entry.transientRecoveryRetriesRemaining > 0 {
            scheduleDeferredFullSynchronizeAll()
        }
        return true
    }

    private func synchronizeHostedView(withId hostedId: ObjectIdentifier, syncLayout: Bool = true) {
        guard ensureInstalled(syncLayout: syncLayout) else { return }
        guard var entry = entriesByHostedId[hostedId] else { return }
        guard let hostedView = entry.hostedView else {
            entriesByHostedId.removeValue(forKey: hostedId)
            return
        }
        guard let anchorView = entry.anchorView, let window else {
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !hostedView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "missingAnchorOrWindow"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    cmuxDebugLog(
                        "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                        "reason=missingAnchorOrWindow frame=\(portalDebugFrame(hostedView.frame))"
                    )
#endif
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
            }
#if DEBUG
            if !hostedView.isHidden {
                cmuxDebugLog("portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 reason=missingAnchorOrWindow")
            }
#endif
            hostedView.isHidden = true
            if entry.visibleInUI {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forHostedId: hostedId,
                    entry: &entry,
                    hostedView: hostedView,
                    reason: "missingAnchorOrWindow"
                )
            }
            return
        }
        guard anchorView.window === window else {
#if DEBUG
            if !hostedView.isHidden {
                cmuxDebugLog(
                    "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                    "reason=anchorWindowMismatch anchorWindow=\(portalDebugToken(anchorView.window?.contentView))"
                )
            }
#endif
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !hostedView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "anchorWindowMismatch"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    cmuxDebugLog(
                        "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                        "reason=anchorWindowMismatch frame=\(portalDebugFrame(hostedView.frame))"
                    )
#endif
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
            }
            hostedView.isHidden = true
            if entry.visibleInUI {
                _ = scheduleTransientRecoveryRetryIfNeeded(
                    forHostedId: hostedId,
                    entry: &entry,
                    hostedView: hostedView,
                    reason: "anchorWindowMismatch"
                )
            }
            return
        }

        _ = synchronizeHostFrameToReference()
        let frameInWindow = effectiveAnchorFrameInWindow(for: anchorView)
        let frameInHostRaw = hostView.convert(frameInWindow, from: nil)
        let frameInHost = Self.pixelSnappedRect(frameInHostRaw, in: hostView)
#if DEBUG
        logBonsplitContainerFrameIfNeeded(anchorView: anchorView, hostedView: hostedView)
#endif
        let hostBounds = hostView.bounds
        let hasFiniteHostBounds =
            hostBounds.origin.x.isFinite &&
            hostBounds.origin.y.isFinite &&
            hostBounds.size.width.isFinite &&
            hostBounds.size.height.isFinite
        let hostBoundsReady = hasFiniteHostBounds && hostBounds.width > 1 && hostBounds.height > 1
        if !hostBoundsReady {
#if DEBUG
            cmuxDebugLog(
                "portal.sync.defer hosted=\(portalDebugToken(hostedView)) " +
                "reason=hostBoundsNotReady host=\(portalDebugFrame(hostBounds)) " +
                "anchor=\(portalDebugFrame(frameInHost)) visibleInUI=\(entry.visibleInUI ? 1 : 0)"
            )
#endif
            if entry.visibleInUI {
                let shouldPreserveVisibleOnTransient = !hostedView.isHidden &&
                    scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "hostBoundsNotReady"
                    )
                if shouldPreserveVisibleOnTransient {
#if DEBUG
                    cmuxDebugLog(
                        "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                        "reason=hostBoundsNotReady frame=\(portalDebugFrame(hostedView.frame))"
                    )
#endif
                    return
                }
            } else {
                resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
            }
            hostedView.isHidden = true
            if entry.visibleInUI {
                if Self.transientRecoveryEnabled {
                    _ = scheduleTransientRecoveryRetryIfNeeded(
                        forHostedId: hostedId,
                        entry: &entry,
                        hostedView: hostedView,
                        reason: "hostBoundsNotReady"
                    )
                } else {
                    scheduleDeferredFullSynchronizeAll()
                }
            }
            return
        }
        let hasFiniteFrame =
            frameInHost.origin.x.isFinite &&
            frameInHost.origin.y.isFinite &&
            frameInHost.size.width.isFinite &&
            frameInHost.size.height.isFinite
        let clampedFrame = frameInHost.intersection(hostBounds)
        let hasVisibleIntersection =
            !clampedFrame.isNull &&
            clampedFrame.width > 1 &&
            clampedFrame.height > 1
        let targetFrame = (hasFiniteFrame && hasVisibleIntersection) ? clampedFrame : frameInHost
        let anchorHidden = Self.isHiddenOrAncestorHidden(anchorView)
        let tinyFrame =
            targetFrame.width <= Self.tinyHideThreshold ||
            targetFrame.height <= Self.tinyHideThreshold
        let revealReadyForDisplay =
            targetFrame.width >= Self.minimumRevealWidth &&
            targetFrame.height >= Self.minimumRevealHeight
        let outsideHostBounds = !hasVisibleIntersection
        let shouldHide =
            !entry.visibleInUI ||
            anchorHidden ||
            tinyFrame ||
            !hasFiniteFrame ||
            outsideHostBounds
        let shouldDeferReveal = !shouldHide && hostedView.isHidden && !revealReadyForDisplay
        let transientRecoveryReason: String? = {
            guard Self.transientRecoveryEnabled else { return nil }
            guard entry.visibleInUI else { return nil }
            if anchorHidden { return "anchorHidden" }
            if !hasFiniteFrame { return "nonFiniteFrame" }
            if outsideHostBounds { return "outsideHostBounds" }
            if tinyFrame { return "tinyFrame" }
            if shouldDeferReveal { return "deferReveal" }
            return nil
        }()
        let didScheduleTransientRecovery: Bool = {
            guard let transientRecoveryReason else { return false }
            return scheduleTransientRecoveryRetryIfNeeded(
                forHostedId: hostedId,
                entry: &entry,
                hostedView: hostedView,
                reason: transientRecoveryReason
            )
        }()
        let shouldPreserveVisibleOnTransientGeometry =
            didScheduleTransientRecovery &&
            shouldHide &&
            entry.visibleInUI &&
            !hostedView.isHidden

        let oldFrame = hostedView.frame
#if DEBUG
        let frameWasClamped = hasFiniteFrame && !Self.rectApproximatelyEqual(frameInHost, targetFrame)
        if frameWasClamped {
            cmuxDebugLog(
                "portal.frame.clamp hosted=\(portalDebugToken(hostedView)) " +
                "anchor=\(portalDebugToken(anchorView)) " +
                "raw=\(portalDebugFrame(frameInHost)) clamped=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
        }
        let collapsedToTiny = oldFrame.width > 1 && oldFrame.height > 1 && tinyFrame
        let restoredFromTiny = (oldFrame.width <= 1 || oldFrame.height <= 1) && !tinyFrame
        if collapsedToTiny {
            cmuxDebugLog(
                "portal.frame.collapse hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        } else if restoredFromTiny {
            cmuxDebugLog(
                "portal.frame.restore hosted=\(portalDebugToken(hostedView)) anchor=\(portalDebugToken(anchorView)) " +
                "old=\(portalDebugFrame(oldFrame)) new=\(portalDebugFrame(targetFrame))"
            )
        }
#endif

        // Hide before updating the frame when this entry should not be visible.
        // This avoids a one-frame flash of unrendered terminal background when a portal
        // briefly transitions through offscreen/tiny geometry during rapid split churn.
        if shouldHide, !hostedView.isHidden, !shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            cmuxDebugLog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=1 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = true
        }
        if shouldPreserveVisibleOnTransientGeometry {
#if DEBUG
            cmuxDebugLog(
                "portal.hidden.deferKeep hosted=\(portalDebugToken(hostedView)) " +
                "reason=\(transientRecoveryReason ?? "unknown") frame=\(portalDebugFrame(hostedView.frame))"
            )
#endif
        }

        if hasFiniteFrame {
            let expectedBounds = NSRect(origin: .zero, size: targetFrame.size)
            var geometryChanged = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if !Self.rectApproximatelyEqual(oldFrame, targetFrame) {
                hostedView.frame = targetFrame
                geometryChanged = true
            }
            if !Self.rectApproximatelyEqual(hostedView.bounds, expectedBounds) {
                hostedView.bounds = expectedBounds
                geometryChanged = true
            }
            CATransaction.commit()
            if geometryChanged {
                hostedView.reconcileGeometryNow()
                hostedView.refreshSurfaceNow(reason: "portal.frameChange")
            }
        }

        if shouldDeferReveal {
#if DEBUG
            if !Self.rectApproximatelyEqual(oldFrame, frameInHost) {
                cmuxDebugLog(
                    "portal.hidden.deferReveal hosted=\(portalDebugToken(hostedView)) " +
                    "frame=\(portalDebugFrame(frameInHost)) min=\(Int(Self.minimumRevealWidth))x\(Int(Self.minimumRevealHeight))"
                )
            }
#endif
        }

        if !shouldHide, hostedView.isHidden, revealReadyForDisplay {
#if DEBUG
            cmuxDebugLog(
                "portal.hidden hosted=\(portalDebugToken(hostedView)) value=0 " +
                "visibleInUI=\(entry.visibleInUI ? 1 : 0) anchorHidden=\(anchorHidden ? 1 : 0) " +
                "tiny=\(tinyFrame ? 1 : 0) revealReady=\(revealReadyForDisplay ? 1 : 0) finite=\(hasFiniteFrame ? 1 : 0) " +
                "outside=\(outsideHostBounds ? 1 : 0) frame=\(portalDebugFrame(targetFrame)) " +
                "host=\(portalDebugFrame(hostBounds))"
            )
#endif
            hostedView.isHidden = false
            // A reveal can happen without any frame delta (same targetFrame), which means the
            // normal frame-change refresh path won't run. Nudge geometry + redraw so newly
            // revealed terminals don't sit on a stale/blank IOSurface until later focus churn.
            hostedView.reconcileGeometryNow()
            hostedView.refreshSurfaceNow(reason: "portal.reveal")
        }

        if transientRecoveryReason == nil {
            resetTransientRecoveryRetryIfNeeded(forHostedId: hostedId, entry: &entry)
        }

#if DEBUG
        cmuxDebugLog(
            "portal.sync.result hosted=\(portalDebugToken(hostedView)) " +
            "anchor=\(portalDebugToken(anchorView)) host=\(portalDebugToken(hostView)) " +
            "hostWin=\(hostView.window?.windowNumber ?? -1) " +
            "old=\(portalDebugFrame(oldFrame)) raw=\(portalDebugFrame(frameInHost)) " +
            "target=\(portalDebugFrame(targetFrame)) hide=\(shouldHide ? 1 : 0) " +
            "entryVisible=\(entry.visibleInUI ? 1 : 0) hostedHidden=\(hostedView.isHidden ? 1 : 0) " +
            "hostBounds=\(portalDebugFrame(hostBounds))"
        )
#endif

        ensureDividerOverlayOnTop()
    }

    private func pruneDeadEntries() {
        let currentWindow = window
        let deadHostedIds = entriesByHostedId.compactMap { hostedId, entry -> ObjectIdentifier? in
            guard entry.hostedView != nil else { return hostedId }
            guard let anchor = entry.anchorView else {
                return entry.visibleInUI ? nil : hostedId
            }

            let anchorInvalidForCurrentHost =
                anchor.window !== currentWindow ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                // During aggressive tab drag/reorder churn, SwiftUI/AppKit can briefly
                // detach/rehome anchor hosts while the terminal should stay visible.
                // Avoid pruning those visible entries so sync/bind recovery can reattach.
                return entry.visibleInUI ? nil : hostedId
            }
            return nil
        }

        for hostedId in deadHostedIds {
            detachHostedView(withId: hostedId)
        }

        let validAnchorIds = Set(entriesByHostedId.compactMap { _, entry in
            entry.anchorView.map { ObjectIdentifier($0) }
        })
        hostedByAnchorId = hostedByAnchorId.filter { validAnchorIds.contains($0.key) }
    }

    func hostedIds() -> Set<ObjectIdentifier> {
        Set(entriesByHostedId.keys)
    }

    func tearDown() {
        removeGeometryObservers()
        for hostedId in Array(entriesByHostedId.keys) {
            detachHostedView(withId: hostedId)
        }
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

}
