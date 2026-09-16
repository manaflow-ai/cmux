import AppKit
import Bonsplit
import CmuxTerminal
import QuartzCore
import SwiftUI

/// Adapts SwiftUI lifecycle callbacks to the terminal portal reconciliation path.
extension GhosttyTerminalView {
    func makeCoordinator() -> Coordinator { Coordinator() }

    static func shouldApplyImmediateHostedStateUpdate(
        desiredVisibleInUI: Bool, hostedViewHasSuperview: Bool, isBoundToCurrentHost: Bool
    ) -> Bool {
        if !desiredVisibleInUI { return true }
        // If this update originates from a stale/replaced host while the hosted view is
        // already attached elsewhere, do not mutate visibility/active state here.
        if isBoundToCurrentHost { return true }
        return !hostedViewHasSuperview
    }

    /// The complete immediate visible/active apply decision.
    ///
    /// Hiding never needs lease ownership or a live binding generation.
    /// Ownership gates SHOWING and re-anchoring; the host a hosted view is
    /// currently bound to is the only one that can un-show it, owner or not.
    /// Gating the hide on the claim leaves a deselected tab's surface on
    /// screen whenever ownership flips without a rebind: the bound host's
    /// visible=false updates defer forever and the hidden tab draws over the
    /// selected one.
    static func immediateHostedStateAction(
        hostOwnsPortal: Bool,
        portalBindingLive: Bool,
        desiredVisibleInUI: Bool,
        hostedViewHasSuperview: Bool,
        isBoundToCurrentHost: Bool
    ) -> GhosttyTerminalImmediateHostedStateAction {
        if portalBindingLive, hostOwnsPortal, shouldApplyImmediateHostedStateUpdate(
            desiredVisibleInUI: desiredVisibleInUI,
            hostedViewHasSuperview: hostedViewHasSuperview,
            isBoundToCurrentHost: isBoundToCurrentHost
        ) {
            return .applyVisibleAndActive
        }
        if !desiredVisibleInUI, isBoundToCurrentHost { return .hideOnly }
        return .deferred
    }

    func makeNSView(context: Context) -> NSView {
        let container = HostContainerView(frame: .zero)
        container.wantsLayer = false
        // The actual terminal surface lives in the AppKit portal layer above SwiftUI.
        // This empty placeholder should not be walked by the accessibility subsystem.
        container.setAccessibilityRole(.none)
        container.setAccessibilityElement(false)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let hostedView = terminalSurface.hostedView
        let coordinator = context.coordinator
        let workspaceAttentionColorSnapshot = workspaceAttentionColor
        let previousDesiredIsActive = coordinator.desiredIsActive
        let previousDesiredIsVisibleInUI = coordinator.desiredIsVisibleInUI
        let previousDesiredPortalZPriority = coordinator.desiredPortalZPriority
        let desiredStateChanged =
            previousDesiredIsActive != isActive ||
            previousDesiredIsVisibleInUI != isVisibleInUI ||
            previousDesiredPortalZPriority != portalZPriority
        coordinator.desiredIsActive = isActive
        coordinator.desiredIsVisibleInUI = isVisibleInUI
        coordinator.desiredShowsUnreadNotificationRing = showsUnreadNotificationRing
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.hostedView = hostedView
#if DEBUG
        if desiredStateChanged {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.swiftui.update id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(terminalSurface.id.uuidString.prefix(5)) visible=\(isVisibleInUI ? 1 : 0) " +
                    "active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            } else {
                cmuxDebugLog(
                    "ws.swiftui.update id=none surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            }
        }
#endif

        let hostContainer = nsView as? HostContainerView
        let ownsCurrentPane = isCurrentPaneOwner()
        let portalExpectedSurfaceId = terminalSurface.id
        let portalExpectedGeneration = terminalSurface.portalBindingGeneration()
        let forwardedDropZone = isVisibleInUI ? paneDropZone : nil
#if DEBUG
        if coordinator.lastPaneDropZone != paneDropZone {
            let oldZone = coordinator.lastPaneDropZone.map { String(describing: $0) } ?? "none"
            let newZone = paneDropZone.map { String(describing: $0) } ?? "none"
            cmuxDebugLog(
                "terminal.paneDropZone surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "old=\(oldZone) new=\(newZone) " +
                "active=\(isActive ? 1 : 0) visible=\(isVisibleInUI ? 1 : 0) " +
                "inWindow=\(hostedView.window != nil ? 1 : 0)"
            )
            coordinator.lastPaneDropZone = paneDropZone
        }
        if paneDropZone != nil, !isVisibleInUI {
            cmuxDebugLog(
                "terminal.paneDropZone.suppress surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "requested=\(String(describing: paneDropZone!)) visible=0 active=\(isActive ? 1 : 0)"
            )
        }
#endif
        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration

        let reconciliationSnapshot = TerminalPortalReconciliationSnapshot(
            attachGeneration: generation,
            expectedSurfaceId: portalExpectedSurfaceId,
            expectedSurfaceGeneration: portalExpectedGeneration,
            paneId: paneId,
            ownershipGeneration: ownershipGeneration,
            isCurrentPaneOwner: isCurrentPaneOwner,
            workspaceAttentionColor: workspaceAttentionColorSnapshot,
            sessionContentWidthPresentation: sessionContentWidthPresentation,
            onFocus: onFocus,
            onTriggerFlash: onTriggerFlash,
            inactiveOverlayColor: inactiveOverlayColor,
            inactiveOverlayOpacity: inactiveOverlayOpacity,
            showsInactiveOverlay: showsInactiveOverlay,
            searchState: searchState,
            dropZone: forwardedDropZone
        )

        let stagePortalReconciliation: @MainActor (
            HostContainerView,
            TerminalPortalReconciliationReasons,
            String
        ) -> Void = { [weak coordinator, weak hostedView, weak terminalSurface] host, reasons, reason in
            guard let coordinator, let hostedView, let terminalSurface else { return }
            Self.stagePortalReconciliation(
                hostedView: hostedView,
                host: host,
                coordinator: coordinator,
                terminalSurface: terminalSurface,
                snapshot: reconciliationSnapshot,
                reasons: reasons,
                reason: reason
            )
        }

        if let host = hostContainer {
            host.onDidMoveToWindow = { [weak host] in
                guard let host else { return }
                stagePortalReconciliation(
                    host,
                    [.bindingRequired, .flushPendingManualSizeReport],
                    "didMoveToWindow"
                )
            }
            // The owner-death wake. Every claim above runs on this host's own
            // edges; the lease owner dying fires none of them, and a pane whose
            // owner dismantled can otherwise wait a full settle budget for an
            // unrelated SwiftUI update before it re-anchors. Parked only while
            // this host owns its pane AND its content is presented; the wake
            // re-checks both live and never writes visible/active state, so it
            // can re-anchor on-screen content but can never reveal a hidden
            // tab (bind is a show path — a hidden survivor waits for its own
            // update instead).
            // `parkPortalVacancyRetry` stores a closure on TerminalSurface, so
            // the retry body retains neither the surface nor its coordinator.
            let vacancyIsCurrentPaneOwner = isCurrentPaneOwner
            coordinator.vacancyRetry = { [weak host, weak coordinator] in
                guard let host, let coordinator else { return }
                guard vacancyIsCurrentPaneOwner() else { return }
                guard coordinator.desiredIsVisibleInUI else { return }
                stagePortalReconciliation(
                    host,
                    [.bindingRequired, .flushPendingManualSizeReport],
                    "hostVacated"
                )
            }
            if ownsCurrentPane, isVisibleInUI {
                // If an earlier update parked this host on a different surface,
                // unregister there first: the stale trampoline would fire THIS
                // coordinator's current retry, so a vacancy on the old surface
                // could drive a claim against the new one.
                if let previous = coordinator.vacancyParkedSurface, previous !== terminalSurface {
                    previous.removePortalVacancyRetry(
                        hostId: ObjectIdentifier(host),
                        instanceSerial: host.instanceSerial
                    )
                }
                coordinator.vacancyParkedSurface = terminalSurface
                let parkedAttachGeneration = generation
                let parkedRetry = coordinator.vacancyRetry
                terminalSurface.parkPortalVacancyRetry(
                    hostId: ObjectIdentifier(host),
                    instanceSerial: host.instanceSerial
                ) { [weak coordinator, weak terminalSurface] in
                    // TerminalSurface drains vacancy retries from RunLoop.main.
                    MainActor.assumeIsolated {
                        guard let coordinator,
                              let terminalSurface,
                              coordinator.attachGeneration == parkedAttachGeneration,
                              coordinator.vacancyParkedSurface === terminalSurface,
                              let parkedRetry else { return }
                        parkedRetry()
                    }
                }
            } else {
                coordinator.vacancyRetry = nil
                coordinator.vacancyParkedSurface?.removePortalVacancyRetry(hostId: ObjectIdentifier(host), instanceSerial: host.instanceSerial)
                coordinator.vacancyParkedSurface = nil
            }
#if DEBUG
            let geometryLogSurfaceId = terminalSurface.id.uuidString.prefix(5)
#endif
            host.onGeometryChanged = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard reconciliationSnapshot.isCurrentPaneOwner() else { return }
                let hostId = ObjectIdentifier(host)
                let bindingRequired =
                    host.window != nil &&
                    (coordinator.lastBoundHostId != hostId ||
                     !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host))
#if DEBUG
                if bindingRequired {
                    cmuxDebugLog(
                        "ws.hostState.rebindOnGeometry surface=\(geometryLogSurfaceId) " +
                        "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                    )
                }
#endif
                stagePortalReconciliation(
                    host,
                    bindingRequired ? [.bindingRequired] : [],
                    "geometryChanged"
                )
            }

            if host.window != nil, ownsCurrentPane {
                let hostId = ObjectIdentifier(host)
                let portalEntryMissing = !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)
                // Notification rings are hosted inside GhosttySurfaceScrollView and update in place.
                // A ring-only state change must not resynchronize the window portal while SwiftUI is
                // invalidating notification UI, or the terminal can be hidden until the next tab switch.
                let shouldBindNow =
                    coordinator.lastBoundHostId != hostId ||
                    hostedView.superview == nil ||
                    portalEntryMissing ||
                    previousDesiredIsVisibleInUI != isVisibleInUI ||
                    previousDesiredPortalZPriority != portalZPriority
                if shouldBindNow {
#if DEBUG
                    if portalEntryMissing {
                        cmuxDebugLog(
                            "ws.hostState.rebindOnUpdate surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                            "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                            "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                        )
                    }
#endif
                    stagePortalReconciliation(
                        host,
                        [.bindingRequired],
                        "update"
                    )
                } else if coordinator.lastSynchronizedHostGeometryRevision != host.geometryRevision {
                    stagePortalReconciliation(host, [], "updateGeometry")
                }
            } else if ownsCurrentPane {
                // Bind is deferred until host moves into a window. Update the
                // existing portal entry's visibleInUI now so that any portal sync
                // that runs before the deferred bind completes won't hide the view.
#if DEBUG
                if desiredStateChanged {
                    cmuxDebugLog(
                        "ws.hostState.deferBind surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                        "reason=hostNoWindow visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority) " +
                        "hostedWindow=\(hostedView.window != nil ? 1 : 0) hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                    )
                }
#endif
                stagePortalReconciliation(host, [], "updateDetached")
            }
        }

        // Every update publishes a complete latest-state reconciliation. More
        // specific callbacks above only add required work (binding or a pending
        // size report); the scheduler coalesces them into this latest closure.
        if let host = hostContainer {
            stagePortalReconciliation(host, [], "updateState")
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        coordinator.desiredIsActive = false
        coordinator.desiredIsVisibleInUI = false
        coordinator.desiredShowsUnreadNotificationRing = false
        coordinator.desiredPortalZPriority = 0
        coordinator.lastBoundHostId = nil
        coordinator.portalReconciliationScheduler.cancel()
        let hostedView = coordinator.hostedView
        let host = nsView as? HostContainerView
        let wasBoundToDismantledHost: Bool = {
            guard let host, let hostedView else { return false }
            guard TerminalWindowPortalRegistry.hasEntry(for: hostedView, boundTo: host),
                  let terminalSurface = hostedView.surfaceView.terminalSurface else {
                return false
            }
            return terminalSurface.ownsPortalHost(
                hostId: ObjectIdentifier(host),
                instanceSerial: host.instanceSerial
            )
        }()
#if DEBUG
        if let hostedView {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.swiftui.dismantle id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            } else {
                cmuxDebugLog(
                    "ws.swiftui.dismantle id=none surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            }
        }
#endif

        // Only the host that is still bound to this surface may clear the
        // shared ring. Do this before preparing a replacement so a synchronous
        // hand-off cannot let the old teardown hide the new owner's ring.
        if wasBoundToDismantledHost {
            hostedView?.setNotificationRing(visible: false)
        }

        if let host {
            host.onDidMoveToWindow = nil
            host.onGeometryChanged = nil
            // The owner's vacate path drops its own wake-up; a candidate that
            // never owned has no vacate path, so drop it here — through the
            // coordinator's reference, since hostedView can already be gone.
            coordinator.vacancyRetry = nil
            coordinator.vacancyParkedSurface?.removePortalVacancyRetry(hostId: ObjectIdentifier(host), instanceSerial: host.instanceSerial)
            coordinator.vacancyParkedSurface = nil
            hostedView?.prepareOwnedPortalHostForTransientReattach(
                hostId: ObjectIdentifier(host),
                instanceSerial: host.instanceSerial,
                reason: "dismantle"
            )
        }

        // Preserve the portal lease across transient rebuilds, but reset the
        // surface-local ring; the next reconciliation reapplies current state.
        hostedView?.setFocusHandler(nil)
        hostedView?.setTriggerFlashHandler(nil)
        hostedView?.setDropZoneOverlay(zone: nil)
        coordinator.hostedView = nil

        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}
