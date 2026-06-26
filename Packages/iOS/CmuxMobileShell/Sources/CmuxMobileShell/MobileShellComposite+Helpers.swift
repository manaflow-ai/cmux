internal import CMUXMobileCore
internal import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    static func normalizedPairingURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CmxPairingURLScheme.hasPairingScheme(trimmed) else {
            return trimmed
        }
        let scalars = trimmed.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func diagnosticSurfaceHandle(_ surfaceID: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in surfaceID.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }

    static func workspaceActionCapabilities(
        from supportedHostCapabilities: Set<String>
    ) -> MobileWorkspaceActionCapabilities {
        MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: supportedHostCapabilities.contains("workspace.actions.v1"),
            supportsReadStateActions: supportedHostCapabilities.contains("workspace.read_state.v1"),
            supportsCloseActions: supportedHostCapabilities.contains("workspace.close.v1")
        )
    }

    static func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }

    /// Routes ordered by network proximity (direct LAN > Tailnet > relay) via the
    /// shared ``CmxRouteCandidateSet`` ranking, replacing the raw priority/id sort
    /// for reconnect dialing.
    ///
    /// This subsumes the old loopback avoidance — loopback ranks last on a
    /// physical phone and first on the simulator — via `preferLoopback`. It also
    /// makes the freshest route win: ``DeviceRegistryService/selectReconnectRoutes(local:registry:)``
    /// persists the fresh registry route ahead of a stale same-tier cached one,
    /// and earlier array position is treated as fresher here, so that order
    /// survives the bare-`[CmxAttachRoute]` boundary and the fresh route is dialed
    /// first instead of being beaten by a stale route with a smaller id.
    static func proximityRankedRoutes(
        _ routes: [CmxAttachRoute],
        preferNonLoopback: Bool
    ) -> [CmxAttachRoute] {
        guard routes.count > 1 else { return routes }
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let candidates = routes.enumerated().map { index, route in
            CmxRouteCandidate(
                route: route,
                source: .localCache,
                lastSeenAt: reference.addingTimeInterval(-Double(index))
            )
        }
        return CmxRouteCandidateSet(candidates)
            .merged(preferLoopback: !preferNonLoopback, maxCandidates: routes.count)
            .map(\.route)
    }
}
