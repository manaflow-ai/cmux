import AppKit
import Bonsplit
import CmuxTerminal
import QuartzCore

extension GhosttyTerminalView {
    func updateDirectHostedTerminal(
        hostedView: GhosttySurfaceScrollView,
        hostContainer: HostContainerView?,
        coordinator: Coordinator,
        hostOwnsPortalNow: Bool,
        generation: Int,
        portalBindingStillLive: @escaping () -> Bool,
        desiredStateChanged: Bool
    ) {
        if let host = hostContainer {
            host.onDidMoveToWindow = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "directHosting.didMoveToWindow"
                ) else { return }
                guard portalBindingStillLive() else { return }
                Self.applyDirectHostedTerminal(
                    hostedView: hostedView,
                    in: host,
                    visibleInUI: coordinator.desiredIsVisibleInUI,
                    active: coordinator.desiredIsActive,
                    notificationRingVisible: coordinator.desiredShowsUnreadNotificationRing,
                    reason: "directTerminalHosting.didMoveToWindow"
                )
                coordinator.lastBoundHostId = ObjectIdentifier(host)
                coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
            }

            host.onGeometryChanged = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "directHosting.geometryChanged"
                ) else { return }
                guard portalBindingStillLive() else { return }
                Self.applyDirectHostedTerminal(
                    hostedView: hostedView,
                    in: host,
                    visibleInUI: coordinator.desiredIsVisibleInUI,
                    active: coordinator.desiredIsActive,
                    notificationRingVisible: coordinator.desiredShowsUnreadNotificationRing,
                    reason: "directTerminalHosting.geometryChanged"
                )
                coordinator.lastBoundHostId = ObjectIdentifier(host)
                coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
            }

            if hostOwnsPortalNow, portalBindingStillLive() {
                Self.applyDirectHostedTerminal(
                    hostedView: hostedView,
                    in: host,
                    visibleInUI: isVisibleInUI,
                    active: isActive,
                    notificationRingVisible: showsUnreadNotificationRing,
                    reason: "directTerminalHosting.update"
                )
                coordinator.lastBoundHostId = ObjectIdentifier(host)
                coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
            }
        }

        if portalBindingStillLive() && hostOwnsPortalNow {
            hostedView.setVisibleInUI(isVisibleInUI)
            hostedView.setActive(isActive)
        } else {
            logDirectHostingDeferredApply(
                hostContainer: hostContainer,
                hostedView: hostedView,
                desiredStateChanged: desiredStateChanged
            )
        }
    }

    private static func applyDirectHostedTerminal(
        hostedView: GhosttySurfaceScrollView,
        in host: HostContainerView,
        visibleInUI: Bool,
        active: Bool,
        notificationRingVisible: Bool,
        reason: String
    ) {
        guard host.window != nil else { return }
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)

        if hostedView.superview !== host {
            hostedView.removeFromSuperview()
            hostedView.translatesAutoresizingMaskIntoConstraints = true
            hostedView.autoresizingMask = [.width, .height]
            host.addSubview(hostedView)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let targetFrame = host.bounds
        if hostedView.frame != targetFrame {
            hostedView.frame = targetFrame
        }
        let targetBounds = NSRect(origin: .zero, size: targetFrame.size)
        if hostedView.bounds != targetBounds {
            hostedView.bounds = targetBounds
        }
        CATransaction.commit()

        hostedView.setVisibleInUI(visibleInUI)
        hostedView.setActive(active)
        hostedView.setNotificationRing(visible: notificationRingVisible)
        let didChangeGeometry = hostedView.reconcileGeometryNow()
        if visibleInUI || didChangeGeometry {
            hostedView.refreshSurfaceNow(reason: reason)
        }
    }

    private func logDirectHostingDeferredApply(
        hostContainer: HostContainerView?,
        hostedView: GhosttySurfaceScrollView,
        desiredStateChanged: Bool
    ) {
#if DEBUG
        guard desiredStateChanged else { return }
        cmuxDebugLog(
            "ws.hostState.deferApply surface=\(terminalSurface.id.uuidString.prefix(5)) " +
            "reason=directHostingOwnershipRejected " +
            "hostWindow=\((hostContainer?.window != nil) ? 1 : 0) " +
            "hostedSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0)"
        )
#else
        _ = hostContainer
        _ = hostedView
        _ = desiredStateChanged
#endif
    }
}
