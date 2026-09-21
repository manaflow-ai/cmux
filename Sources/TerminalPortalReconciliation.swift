import AppKit
import CMUXMobileCore
import Bonsplit
import CmuxTerminal
import Foundation

/// Immutable representable input consumed when the queued portal turn runs.
/// Mutable visibility/active values remain on the coordinator so coalesced
/// callbacks always apply the newest state.
@MainActor
struct TerminalPortalReconciliationSnapshot {
    let attachGeneration: Int
    let expectedSurfaceId: UUID
    let expectedSurfaceGeneration: UInt64
    let paneId: PaneID
    let ownershipGeneration: UInt64
    let isCurrentPaneOwner: @MainActor () -> Bool
    let workspaceAttentionColor: WorkspaceAttentionColor
    let sessionContentWidthPresentation: SessionContentWidthPresentation
    let onFocus: ((UUID) -> Void)?
    let onTriggerFlash: (() -> Void)?
    let inactiveOverlayColor: NSColor
    let inactiveOverlayOpacity: Double
    let showsInactiveOverlay: Bool
    let searchState: TerminalSurface.SearchState?
    let dropZone: DropZone?
}

extension GhosttyTerminalView {
    static func stagePortalReconciliation(
        hostedView: GhosttySurfaceScrollView,
        host: HostContainerView,
        coordinator: Coordinator,
        terminalSurface: TerminalSurface,
        snapshot: TerminalPortalReconciliationSnapshot,
        reasons: TerminalPortalReconciliationReasons,
        transition: TerminalWorkContext.Transition = .unknown,
        reason: String
    ) {
        // Capture the source before the run-loop hop. Binding is required for
        // moves and ordinary updates too, so it does not establish a reveal.
        let diagnostics = TerminalGeometryDiagnostics()
        let enclosingTransition = diagnostics.context(workspaceID: terminalSurface.tabId, transition: .unknown).transition
        let fallbackTransition = transition == .unknown ? diagnostics.resizeTransition(in: host.window) : transition
        let capturedTransition = enclosingTransition == .unknown ? fallbackTransition : enclosingTransition
        coordinator.portalReconciliationScheduler.stage(reasons: reasons, transition: capturedTransition) {
            [weak host, weak hostedView, weak coordinator, weak terminalSurface] request in
            let reasons = request.reasons
            guard let host, let hostedView, let coordinator, let terminalSurface else { return }
            guard coordinator.attachGeneration == snapshot.attachGeneration else { return }
            guard coordinator.hostedView === hostedView else { return }
            let work = TerminalGeometryDiagnostics().begin(
                .geometryPublication, workspaceID: terminalSurface.tabId,
                transition: request.transition
            )
            defer { work.end() }

            let portalBindingLive = terminalSurface.canAcceptPortalBinding(
                expectedSurfaceId: snapshot.expectedSurfaceId,
                expectedGeneration: snapshot.expectedSurfaceGeneration
            )
            let ownsCurrentPane = snapshot.isCurrentPaneOwner()
            let hostOwnsPortal =
                portalBindingLive &&
                ownsCurrentPane &&
                terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: snapshot.paneId,
                    instanceSerial: host.instanceSerial,
                    ownershipGeneration: snapshot.ownershipGeneration,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    allowsAuthorityAcquisition: ownsCurrentPane,
                    reason: reason
                )

            if hostOwnsPortal {
                configureHostedView(
                    hostedView,
                    terminalSurface: terminalSurface,
                    coordinator: coordinator,
                    snapshot: snapshot
                )
            }

            let hostId = ObjectIdentifier(host)
            let wasBoundToHost = TerminalWindowPortalRegistry.isHostedView(
                hostedView,
                boundTo: host
            )
            if host.window != nil, hostOwnsPortal {
                let bindingRequired =
                    reasons.contains(.bindingRequired) ||
                    coordinator.lastBoundHostId != hostId ||
                    hostedView.superview == nil ||
                    !wasBoundToHost
                if bindingRequired {
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority,
                        expectedSurfaceId: snapshot.expectedSurfaceId,
                        expectedGeneration: snapshot.expectedSurfaceGeneration
                    )
                    coordinator.lastBoundHostId = hostId
                    coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
                } else if coordinator.lastSynchronizedHostGeometryRevision != host.geometryRevision {
                    TerminalWindowPortalRegistry.synchronizeForAnchor(host, syncLayout: false)
                    coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
                }
            } else if hostOwnsPortal,
                      TerminalWindowPortalRegistry.hasEntry(for: hostedView, boundTo: host) {
                // Preserve the latest visibility intent while the SwiftUI host
                // is temporarily detached. Its next move-to-window callback
                // stages the authoritative rebind.
                TerminalWindowPortalRegistry.updateEntryVisibility(
                    for: hostedView,
                    visibleInUI: coordinator.desiredIsVisibleInUI
                )
            }

            let isBoundToCurrentHost = TerminalWindowPortalRegistry.isHostedView(
                hostedView,
                boundTo: host
            )
            let hasCurrentHostEntry = TerminalWindowPortalRegistry.hasEntry(
                for: hostedView,
                boundTo: host
            )
            let isCurrentPortalHost = terminalSurface.ownsPortalHost(
                hostId: hostId,
                instanceSerial: host.instanceSerial
            )
            // Only the current portal owner may publish a ring. A host that is
            // still the bound owner may also publish a hide, which clears a
            // stale ring during a hand-off without allowing an old coordinator
            // to resurrect one on the replacement host.
            if hostOwnsPortal || (
                !coordinator.desiredShowsUnreadNotificationRing
                    && isCurrentPortalHost
            ) {
                hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
            }

            if !coordinator.desiredIsVisibleInUI,
               hasCurrentHostEntry,
               isCurrentPortalHost {
                TerminalWindowPortalRegistry.updateEntryVisibility(
                    for: hostedView,
                    visibleInUI: false
                )
            }

            switch immediateHostedStateAction(
                hostOwnsPortal: hostOwnsPortal,
                portalBindingLive: portalBindingLive,
                desiredVisibleInUI: coordinator.desiredIsVisibleInUI,
                hostedViewHasSuperview: hostedView.superview != nil,
                isBoundToCurrentHost: isBoundToCurrentHost
            ) {
            case .applyVisibleAndActive:
                hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                hostedView.setActive(coordinator.desiredIsActive)
            case .hideOnly:
                TerminalWindowPortalRegistry.updateEntryVisibility(
                    for: hostedView,
                    visibleInUI: false
                )
                hostedView.setVisibleInUI(false)
            case .deferred:
                break
            }
            if portalBindingLive {
                hostedView.cloudTerminalOverlay.updateAnchor(
                    host, visible: coordinator.desiredIsVisibleInUI,
                    ownershipGeneration: snapshot.ownershipGeneration
                )
                hostedView.synchronizeCloudTerminalReconnectOverlay()
            }
            if hostOwnsPortal, reasons.contains(.flushPendingManualSizeReport) {
                terminalSurface.flushPendingManualSizeReportIfAttached()
            }
        }
    }

    private static func configureHostedView(
        _ hostedView: GhosttySurfaceScrollView,
        terminalSurface: TerminalSurface,
        coordinator: Coordinator,
        snapshot: TerminalPortalReconciliationSnapshot
    ) {
        // The hosted view is created with the surface, but re-attach here in
        // case transient teardown retired its native-view association before
        // this reconciliation turn flushed.
        hostedView.attachSurface(terminalSurface)
        hostedView.setWorkspaceAttentionColor(snapshot.workspaceAttentionColor)
        hostedView.setSessionContentWidthPresentation(snapshot.sessionContentWidthPresentation)
        hostedView.setFocusHandler { [weak terminalSurface] in
            guard let terminalSurface else { return }
            snapshot.onFocus?(terminalSurface.id)
        }
        hostedView.setTriggerFlashHandler(snapshot.onTriggerFlash)
        hostedView.setPaneDropContext(TerminalPaneDropContext(
            workspaceId: terminalSurface.tabId,
            panelId: terminalSurface.id,
            paneId: snapshot.paneId
        ))
        hostedView.setInactiveOverlay(
            color: snapshot.inactiveOverlayColor,
            opacity: CGFloat(snapshot.inactiveOverlayOpacity),
            visible: snapshot.showsInactiveOverlay
        )
        hostedView.setSearchOverlay(searchState: snapshot.searchState)
        hostedView.syncKeyStateIndicator(text: terminalSurface.currentKeyStateIndicatorText)
        hostedView.setDropZoneOverlay(zone: snapshot.dropZone)
    }
}
