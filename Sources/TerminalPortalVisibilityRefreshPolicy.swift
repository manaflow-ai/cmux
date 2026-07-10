import AppKit
import CmuxTerminal

extension GhosttyTerminalView {
    @discardableResult
    static func schedulePortalMutation(
        host: TerminalPortalHostContainerView,
        hostedView: GhosttySurfaceScrollView,
        terminalSurface: TerminalSurface,
        coordinator: Coordinator,
        snapshot: TerminalPortalMutationSnapshot,
        reason: String
    ) -> Task<Void, Never>? {
        guard coordinator.attachGeneration == snapshot.attachGeneration else { return nil }
        let hostId = ObjectIdentifier(host)
        let candidatePresentationIsVisible: Bool
        if case .visible = snapshot.portalPresentation() {
            candidatePresentationIsVisible = true
        } else {
            candidatePresentationIsVisible = false
        }
        let isDistinctReplacement = !terminalSurface.isPortalHostOwner(hostId: hostId)
        hostedView.updateTransientPortalHostCandidate(
            hostId: hostId,
            ownershipGeneration: snapshot.ownershipGeneration,
            isUsable: isDistinctReplacement && candidatePresentationIsVisible &&
                terminalSurface.portalHostIsUsable(
                    inWindow: host.window != nil,
                    bounds: host.bounds
                )
        )
        let drain = coordinator.portalMutationScheduler.schedule {
            @MainActor [weak host, weak hostedView, weak terminalSurface, weak coordinator] in
            guard let host, let hostedView, let terminalSurface, let coordinator else { return }
            guard coordinator.attachGeneration == snapshot.attachGeneration else { return }
            guard terminalSurface.canAcceptPortalBinding(
                expectedSurfaceId: snapshot.expectedSurfaceId,
                expectedGeneration: snapshot.expectedSurfaceGeneration
            ) else { return }
            Self.applyPortalMutation(
                host: host,
                hostedView: hostedView,
                terminalSurface: terminalSurface,
                coordinator: coordinator,
                snapshot: snapshot,
                reason: reason
            )
        }
        Task { @MainActor [weak hostedView] in
            await drain.value
            hostedView?.unregisterTransientPortalHostCandidate(
                hostId: hostId,
                ownershipGeneration: snapshot.ownershipGeneration
            )
        }
        return drain
    }

    static func installPortalHostHandlers(
        host: TerminalPortalHostContainerView,
        hostedView: GhosttySurfaceScrollView,
        terminalSurface: TerminalSurface,
        coordinator: Coordinator,
        snapshot: TerminalPortalMutationSnapshot
    ) {
        let hostId = ObjectIdentifier(host)
        let callbackIsCurrent = {
            @MainActor [weak host, weak terminalSurface, weak coordinator] in
            guard let host, let terminalSurface, let coordinator,
                  coordinator.attachGeneration == snapshot.attachGeneration,
                  terminalSurface.isPortalHostOwner(hostId: ObjectIdentifier(host)),
                  terminalSurface.canAcceptPortalBinding(
                      expectedSurfaceId: snapshot.expectedSurfaceId,
                      expectedGeneration: snapshot.expectedSurfaceGeneration
                  ),
                  case .visible = snapshot.portalPresentation() else {
                return false
            }
            return true
        }
        hostedView.setPortalHostHandlers(
            ownerHostId: hostId,
            focusHandler: {
                guard callbackIsCurrent() else { return }
                snapshot.onFocus?(snapshot.expectedSurfaceId)
            },
            triggerFlashHandler: {
                guard callbackIsCurrent() else { return }
                snapshot.onTriggerFlash?()
            }
        )
    }

    static func shouldBindPortalHost(
        boundHostMatches: Bool,
        hostedViewHasSuperview: Bool,
        portalEntryMatchesHost: Bool,
        lastAppliedIsVisibleInUI: Bool?,
        lastAppliedPortalZPriority: Int?,
        desiredPortalZPriority: Int
    ) -> Bool {
        !boundHostMatches ||
            !hostedViewHasSuperview ||
            !portalEntryMatchesHost ||
            lastAppliedIsVisibleInUI != true ||
            lastAppliedPortalZPriority != desiredPortalZPriority
    }

    static func shouldApplyImmediateHostedStateUpdate(
        desiredVisibleInUI: Bool, hostedViewHasSuperview: Bool, isBoundToCurrentHost: Bool
    ) -> Bool {
        if !desiredVisibleInUI { return true }
        // A replaced host cannot mutate state while the hosted view is attached elsewhere.
        if isBoundToCurrentHost { return true }
        return !hostedViewHasSuperview
    }
}

enum TerminalPortalVisibilityRefreshPolicy {
    case immediate
    case deferredToPortal

    @MainActor
    func refresh(hostedView: GhosttySurfaceScrollView) {
        switch self {
        case .immediate:
            hostedView.refreshSurfaceNow(reason: "setVisibleInUI")
        case .deferredToPortal:
            break
        }
    }
}

extension GhosttySurfaceScrollView {
    func prepareOwnedPortalHostForTransientReattach(hostId: ObjectIdentifier, reason: String) {
        guard let terminalSurface = surfaceView.terminalSurface,
              terminalSurface.isPortalHostOwner(hostId: hostId) else { return }
        guard let ownershipGeneration = terminalSurface.preparePortalHostReplacementIfOwned(
            hostId: hostId,
            reason: reason
        ) else { return }
        TerminalWindowPortalRegistry.prepareForTransientReattach(
            hostedView: self,
            ownershipGeneration: ownershipGeneration
        )
    }

    func updateTransientPortalHostCandidate(
        hostId: ObjectIdentifier,
        ownershipGeneration: UInt64,
        isUsable: Bool
    ) {
        TerminalWindowPortalRegistry.updateTransientReattachCandidate(
            hostedView: self,
            hostId: hostId,
            ownershipGeneration: ownershipGeneration,
            isUsable: isUsable
        )
    }

    func unregisterTransientPortalHostCandidate(
        hostId: ObjectIdentifier,
        ownershipGeneration: UInt64? = nil
    ) {
        TerminalWindowPortalRegistry.unregisterTransientReattachCandidate(
            hostedView: self,
            hostId: hostId,
            ownershipGeneration: ownershipGeneration
        )
    }

    /// `TerminalSurfacePaneHosting` compatibility. App presentation paths choose a policy explicitly.
    func setVisibleInUI(_ visible: Bool) {
        setVisibleInUI(visible, refreshPolicy: .deferredToPortal)
    }

    func setPortalHostHandlers(
        ownerHostId: ObjectIdentifier,
        focusHandler: (() -> Void)?,
        triggerFlashHandler: (() -> Void)?
    ) {
        setFocusHandler(focusHandler)
        setTriggerFlashHandler(triggerFlashHandler)
        portalCallbackOwnerHostId = ownerHostId
    }

    func clearPortalHostHandlersIfOwned(ownerHostId: ObjectIdentifier) {
        guard portalCallbackOwnerHostId == ownerHostId else { return }
        portalCallbackOwnerHostId = nil
        setFocusHandler(nil)
        setTriggerFlashHandler(nil)
        setDropZoneOverlay(zone: nil)
    }

    func makeSurfaceFirstResponder(
        in window: NSWindow,
        refreshPolicy: TerminalPortalVisibilityRefreshPolicy
    ) -> Bool {
        guard case .deferredToPortal = refreshPolicy else {
            return window.makeFirstResponder(surfaceView)
        }
        let wasDeferred = surfaceView.defersFirstResponderRefreshToPortal
        surfaceView.defersFirstResponderRefreshToPortal = true
        defer { surfaceView.defersFirstResponderRefreshToPortal = wasDeferred }
        return window.makeFirstResponder(surfaceView)
    }
}
