import CMUXMobileCore
import CmuxMobilePairedMac

extension MobileShellComposite {
    static func validatedReconnectRoutes(
        local: [CmxAttachRoute],
        registry: [CmxAttachRoute]?,
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> [CmxAttachRoute] {
        let routes = DeviceRegistryService.resolvedReconnectRoutes(
            local: local,
            registry: registry
        )
        guard routes != local else { return local }
        guard firstReconnectHostPortRoute(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ) != nil else {
            return local
        }
        return routes
    }

    static func shouldRefreshReconnectRoutesBeforeDial(
        local: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> Bool {
        guard firstReconnectHostPortRoute(
            local,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ) != nil else { return true }
        guard preferNonLoopback else { return false }
        return firstReconnectHostPortRoute(
            local.filter { $0.kind != .debugLoopback },
            supportedKinds: supportedKinds
        ) == nil
    }

    static func secondaryAggregationCandidates(
        from macs: [MobilePairedMac],
        foregroundMacDeviceIDs: Set<String>
    ) -> [MobilePairedMac] {
        Array(macs.lazy.filter { mac in
            !mac.macDeviceID.isEmpty && !foregroundMacDeviceIDs.contains(mac.macDeviceID)
        }.prefix(maximumAutomaticSecondaryMacSubscriptions))
    }
}
