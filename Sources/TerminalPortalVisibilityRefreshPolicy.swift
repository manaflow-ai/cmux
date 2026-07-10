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
    func setVisibleInUI(_ visible: Bool) {
        setVisibleInUI(visible, refreshPolicy: .immediate)
    }
}
