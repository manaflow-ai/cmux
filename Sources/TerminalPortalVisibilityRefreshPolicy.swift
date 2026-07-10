import AppKit

extension GhosttyTerminalView {
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
