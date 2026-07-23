internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import CmuxMobileShellModel

extension MobileShellComposite {
    /// Select one authoritative stored row per physical device identifier.
    ///
    /// UUID spellings share a lowercase identity, while opaque identifiers stay
    /// case-sensitive. The freshest row owns all routes and metadata; no route
    /// or customization fields are merged from an older alias.
    static func coalescePairedMacsByCanonicalDeviceID(
        _ macs: [MobilePairedMac]
    ) -> [MobilePairedMac] {
        var selectedByDeviceID: [String: MobilePairedMac] = [:]
        var deviceOrder: [String] = []

        for mac in macs where !mac.macDeviceID.isEmpty {
            let canonicalDeviceID = cmxCanonicalDeviceID(mac.macDeviceID)
            guard let selected = selectedByDeviceID[canonicalDeviceID] else {
                selectedByDeviceID[canonicalDeviceID] = mac
                deviceOrder.append(canonicalDeviceID)
                continue
            }
            let shouldReplace: Bool
            let candidateUsesCanonicalSpelling = mac.macDeviceID == canonicalDeviceID
            let selectedUsesCanonicalSpelling = selected.macDeviceID == canonicalDeviceID
            if mac.lastSeenAt != selected.lastSeenAt {
                shouldReplace = mac.lastSeenAt > selected.lastSeenAt
            } else if candidateUsesCanonicalSpelling != selectedUsesCanonicalSpelling {
                shouldReplace = candidateUsesCanonicalSpelling
            } else if mac.isActive != selected.isActive {
                shouldReplace = mac.isActive
            } else {
                shouldReplace = mac.id < selected.id
            }
            if shouldReplace {
                selectedByDeviceID[canonicalDeviceID] = mac
            }
        }

        return deviceOrder.compactMap { deviceID in
            guard var selected = selectedByDeviceID[deviceID] else { return nil }
            selected.macDeviceID = deviceID
            return selected
        }
    }

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
            ) ?? "device:\(mac.id)"
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

    /// Selects one logical client for each cryptographic Iroh endpoint.
    ///
    /// Presentation coalescing intentionally includes the reported name and
    /// instance tag, but the Iroh server admits only one authoritative control
    /// connection per EndpointID. Stale stored rows must therefore share one
    /// connection owner even when their presentation metadata differs.
    static func coalescePairedMacsByIrohEndpointAuthority(
        _ macs: [MobilePairedMac],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> [MobilePairedMac] {
        var selectedByKey: [String: MobilePairedMac] = [:]
        var orderByKey: [String: Int] = [:]

        for (index, mac) in macs.enumerated() {
            let key = irohEndpointID(
                for: mac,
                supportedKinds: supportedKinds,
                preferNonLoopback: preferNonLoopback
            ).map { "iroh-authority:\($0)" } ?? "device:\(mac.id)"
            orderByKey[key] = min(orderByKey[key] ?? index, index)
            guard let existing = selectedByKey[key] else {
                selectedByKey[key] = mac
                continue
            }
            selectedByKey[key] = mac.sortsBeforeDuplicate(existing) ? mac : existing
        }

        return selectedByKey
            .sorted { lhs, rhs in
                (orderByKey[lhs.key] ?? .max) < (orderByKey[rhs.key] ?? .max)
            }
            .map(\.value)
    }

    static func irohEndpointID(
        for mac: MobilePairedMac,
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> String? {
        let reconnectRoutes = storedReconnectRoutes(
            mac.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        )
        guard case let .peer(identity, _)? = reconnectRoutes.first?.endpoint else {
            return nil
        }
        return identity.endpointID
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

    func macDeviceIDAliasSetsByPairedMacID(
        in macs: [MobilePairedMac],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> [String: Set<String>] {
        macDeviceIDAliasesByPairedMacID(
            in: macs,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ).mapValues(Set.init)
    }

    func macDeviceIDAliasesByPairedMacID(
        in macs: [MobilePairedMac],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> [String: [String]] {
        var groupKeyByPairingID: [String: String] = [:]
        var idsByGroupKey: [String: [String]] = [:]
        for mac in macs {
            let key = mac.dialEndpointKey(
                supportedKinds: supportedKinds,
                preferNonLoopback: preferNonLoopback
            ) ?? "device:\(mac.id)"
            groupKeyByPairingID[mac.id] = key
            idsByGroupKey[key, default: []].append(mac.macDeviceID)
        }

        var result: [String: [String]] = [:]
        for (pairingID, groupKey) in groupKeyByPairingID {
            result[pairingID] = idsByGroupKey[groupKey] ?? []
        }
        return result
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
        let reconnectRoutes = MobileShellComposite.storedReconnectRoutes(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        )
        if case let .peer(identity, _)? = reconnectRoutes.first?.endpoint {
            return "iroh:\(identity.endpointID):name:\(displayName.lowercased()):instance:\(instanceTag ?? "")"
        }
        guard let (host, port) = MobileShellComposite.firstReconnectHostPortRoute(
            reconnectRoutes,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ), let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            return nil
        }
        return "host:\(normalizedHost.lowercased()):\(port):name:\(displayName.lowercased()):instance:\(instanceTag ?? "")"
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
