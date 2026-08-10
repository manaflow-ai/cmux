import AppKit
import Bonsplit
import CmuxTerminal
import Foundation

struct TerminalPortalReconciliationReasons: OptionSet {
    let rawValue: UInt8

    static let bindingRequired = Self(rawValue: 1 << 0)
    static let flushPendingManualSizeReport = Self(rawValue: 1 << 1)
}

/// Owns the boundary between SwiftUI/AppKit callbacks and terminal portal mutations.
///
/// `NSViewRepresentable.updateNSView`, `NSView.layout`, and move-to-window callbacks
/// can run while SwiftUI or AppKit is already resolving the hosting hierarchy. Portal
/// binding reparents and resizes the real terminal view, so doing it from those
/// callbacks can synchronously re-enter `NSHostingView` layout on macOS 15.
///
/// Each representable coordinator owns one scheduler. Repeated callbacks retain the
/// latest reconciliation closure while accumulating required work, then flush after
/// the originating framework callback has returned.
@MainActor
final class TerminalPortalReconciliationScheduler {
    private var pendingReasons: TerminalPortalReconciliationReasons = []
    private var pendingReconciliation: (@MainActor (TerminalPortalReconciliationReasons) -> Void)?
    private var isFlushScheduled = false

    func stage(
        reasons: TerminalPortalReconciliationReasons = [],
        reconciliation: @escaping @MainActor (TerminalPortalReconciliationReasons) -> Void
    ) {
        pendingReasons.formUnion(reasons)
        pendingReconciliation = reconciliation
        scheduleFlushIfNeeded()
    }

    func cancel() {
        pendingReasons = []
        pendingReconciliation = nil
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            // RunLoop guarantees main-thread delivery, but Foundation does not
            // annotate this callback with MainActor.
            MainActor.assumeIsolated {
                self?.flushPendingReconciliation()
            }
        }
    }

    /// Flushes the staged reconciliation at a caller-owned safe boundary.
    func flushPendingReconciliation() {
        let reasons = pendingReasons
        let reconciliation = pendingReconciliation
        pendingReasons = []
        pendingReconciliation = nil
        isFlushScheduled = false
        reconciliation?(reasons)
    }
}

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
        reason: String
    ) {
        coordinator.portalReconciliationScheduler.stage(reasons: reasons) {
            [weak host, weak hostedView, weak coordinator, weak terminalSurface] reasons in
            guard let host, let hostedView, let coordinator, let terminalSurface else { return }
            guard coordinator.attachGeneration == snapshot.attachGeneration else { return }
            guard coordinator.hostedView === hostedView else { return }

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
        hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
        hostedView.setSearchOverlay(searchState: snapshot.searchState)
        hostedView.syncKeyStateIndicator(text: terminalSurface.currentKeyStateIndicatorText)
        hostedView.setDropZoneOverlay(zone: snapshot.dropZone)
    }
}
