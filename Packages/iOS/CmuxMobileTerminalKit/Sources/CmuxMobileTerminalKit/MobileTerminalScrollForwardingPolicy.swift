public import CMUXMobileCore

/// Decides whether a mobile terminal scroll gesture must be sent to the Mac.
public struct MobileTerminalScrollForwardingPolicy: Sendable {
    public struct Decision: Equatable, Sendable {
        public let appliesLocally: Bool
        public let forwardsToHost: Bool
        public let requestsScrollbackHydration: Bool

        public init(
            appliesLocally: Bool,
            forwardsToHost: Bool,
            requestsScrollbackHydration: Bool
        ) {
            self.appliesLocally = appliesLocally
            self.forwardsToHost = forwardsToHost
            self.requestsScrollbackHydration = requestsScrollbackHydration
        }
    }

    /// Creates the forwarding policy.
    public init() {}

    /// Legacy predicate for whether a primary-screen scroll may apply locally.
    ///
    /// New call sites should use ``decision(activeScreen:decouplePrimaryScreenScroll:localMirrorCanServePrimaryScroll:localMirrorRequiresHydration:localMirrorRequestsMoreScrollback:)``
    /// so an unhydrated or truncated local mirror falls back to the host.
    /// - Parameter activeScreen: The screen currently rendered by the mobile
    ///   Ghostty mirror.
    /// - Returns: `true` when the scroll should be sent to the Mac.
    public func shouldApplyLocally(
        activeScreen: MobileTerminalRenderGridFrame.Screen,
        decouplePrimaryScreenScroll: Bool
    ) -> Bool {
        decouplePrimaryScreenScroll && activeScreen == .primary
    }

    /// Legacy predicate for whether a scroll must be sent to the Mac.
    ///
    /// New call sites should use ``decision(activeScreen:decouplePrimaryScreenScroll:localMirrorCanServePrimaryScroll:localMirrorRequiresHydration:localMirrorRequestsMoreScrollback:)``.
    public func shouldForwardToHost(
        activeScreen: MobileTerminalRenderGridFrame.Screen,
        decouplePrimaryScreenScroll: Bool
    ) -> Bool {
        activeScreen == .alternate || !decouplePrimaryScreenScroll
    }

    public func decision(
        activeScreen: MobileTerminalRenderGridFrame.Screen,
        decouplePrimaryScreenScroll: Bool,
        localMirrorCanServePrimaryScroll: Bool,
        localMirrorRequiresHydration: Bool,
        localMirrorRequestsMoreScrollback: Bool = false
    ) -> Decision {
        guard activeScreen == .primary else {
            return Decision(
                appliesLocally: false,
                forwardsToHost: true,
                requestsScrollbackHydration: false
            )
        }
        guard decouplePrimaryScreenScroll else {
            return Decision(
                appliesLocally: false,
                forwardsToHost: true,
                requestsScrollbackHydration: false
            )
        }
        guard localMirrorCanServePrimaryScroll else {
            return Decision(
                appliesLocally: false,
                forwardsToHost: true,
                requestsScrollbackHydration: localMirrorRequiresHydration
            )
        }
        if localMirrorRequestsMoreScrollback {
            return Decision(
                appliesLocally: true,
                forwardsToHost: true,
                requestsScrollbackHydration: true
            )
        }
        return Decision(
            appliesLocally: true,
            forwardsToHost: false,
            requestsScrollbackHydration: false
        )
    }
}
