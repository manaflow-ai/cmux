internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import CmuxMobileShellModel

extension MobileShellComposite {
    /// Collapse duplicate paired-Mac rows that have the same Mac-reported name
    /// and dial the same host/port.
    ///
    /// A device can accumulate multiple Mac device ids for the same physical host
    /// across debug/reload/pairing paths. The user's Computers screen is a list
    /// of reachable computers, but a dial endpoint alone is not a durable
    /// identity. Require the Mac-reported display name as the second signal
    /// before treating rows as one logical computer. Prefer the active row, then
    /// the freshest route record.
    static func coalescePairedMacsByDialEndpoint(
        _ macs: [MobilePairedMac],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> [MobilePairedMac] {
        var selectedByKey: [String: MobilePairedMac] = [:]
        var orderByKey: [String: Int] = [:]

        for (index, mac) in macs.enumerated() {
            let key = mac.dialEndpointKey(
                supportedKinds: supportedKinds,
                preferNonLoopback: preferNonLoopback
            ) ?? "device:\(mac.macDeviceID)"
            orderByKey[key] = min(orderByKey[key] ?? index, index)
            guard let existing = selectedByKey[key] else {
                selectedByKey[key] = mac
                continue
            }
            if mac.sortsBeforeDuplicate(existing) {
                selectedByKey[key] = mac.mergingCustomization(from: existing)
            } else {
                selectedByKey[key] = existing.mergingCustomization(from: mac)
            }
        }

        return selectedByKey
            .sorted { lhs, rhs in
                (orderByKey[lhs.key] ?? .max) < (orderByKey[rhs.key] ?? .max)
            }
            .map(\.value)
    }

    static func macDeviceIDsForLogicalPairedMac(
        _ macDeviceID: String,
        in macs: [MobilePairedMac],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> [String] {
        guard let target = macs.first(where: { $0.macDeviceID == macDeviceID }),
              let key = target.dialEndpointKey(supportedKinds: supportedKinds, preferNonLoopback: preferNonLoopback) else {
            return [macDeviceID]
        }
        let matching = macs.filter {
            $0.dialEndpointKey(supportedKinds: supportedKinds, preferNonLoopback: preferNonLoopback) == key
        }.map(\.macDeviceID)
        return matching.isEmpty ? [macDeviceID] : matching
    }
}

private extension MobilePairedMac {
    @MainActor
    func dialEndpointKey(
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> String? {
        guard let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else {
            return nil
        }
        guard let (host, port) = MobileShellComposite.firstReconnectHostPortRoute(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ), let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            return nil
        }
        return "host:\(normalizedHost.lowercased()):\(port):name:\(displayName.lowercased())"
    }

    func mergingCustomization(from other: MobilePairedMac) -> MobilePairedMac {
        var merged = self
        if merged.customName?.isEmpty ?? true {
            merged.customName = other.customName
        }
        if merged.customColor?.isEmpty ?? true {
            merged.customColor = other.customColor
        }
        if merged.customIcon?.isEmpty ?? true {
            merged.customIcon = other.customIcon
        }
        return merged
    }

    func sortsBeforeDuplicate(_ other: MobilePairedMac) -> Bool {
        if isActive != other.isActive {
            return isActive
        }
        if lastSeenAt != other.lastSeenAt {
            return lastSeenAt > other.lastSeenAt
        }
        return macDeviceID < other.macDeviceID
    }
}
