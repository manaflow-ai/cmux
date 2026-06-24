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

    static func secondaryAggregationCandidates(
        from macs: [MobilePairedMac],
        foregroundMacDeviceID: String?
    ) -> [MobilePairedMac] {
        Array(macs.lazy.filter { mac in
            !mac.macDeviceID.isEmpty && mac.macDeviceID != foregroundMacDeviceID
        }.prefix(maximumAutomaticSecondaryMacCount))
    }
}
