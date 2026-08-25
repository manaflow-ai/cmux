internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import CmuxMobileShellModel

extension MobileShellComposite {
    /// Select one authoritative stored row per exact device and build pairing.
    ///
    /// UUID spellings share a lowercase identity, while opaque identifiers stay
    /// case-sensitive. The freshest row owns all routes and metadata; no route
    /// or customization fields are merged from an older alias.
    static func coalescePairedMacsByCanonicalDeviceID(
        _ macs: [MobilePairedMac]
    ) -> [MobilePairedMac] {
        var selectedByPairing: [MacPairingKey: MobilePairedMac] = [:]
        var pairingOrder: [MacPairingKey] = []

        for mac in macs where !mac.macDeviceID.isEmpty {
            let canonicalDeviceID = cmxCanonicalDeviceID(mac.macDeviceID)
            let pairingKey = MacPairingKey(
                macDeviceID: canonicalDeviceID,
                instanceTag: mac.instanceTag
            )
            guard let selected = selectedByPairing[pairingKey] else {
                selectedByPairing[pairingKey] = mac
                pairingOrder.append(pairingKey)
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
                selectedByPairing[pairingKey] = mac
            }
        }

        return pairingOrder.compactMap { pairingKey in
            guard var selected = selectedByPairing[pairingKey] else { return nil }
            selected.macDeviceID = pairingKey.canonicalMacDeviceID
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
            let key = mac.scopedDialEndpointKey(
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
    /// instance tag. Iroh endpoint authority is also scoped by the stored
    /// instance tag, so a shared endpoint cannot merge Stable and Nightly.
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
            ).map {
                let modeScope = mac.connectionMethodRawValue ?? "default"
                return "iroh-authority:mode:\(modeScope):\(Self.scopedIrohEndpointID(endpointID: $0, instanceTag: mac.instanceTag))"
            }
                ?? "device:\(mac.id)"
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
            preferNonLoopback: preferNonLoopback,
            transportMode: mac.storedTransportMode
        )
        guard case let .peer(identity, _)? = reconnectRoutes.first?.endpoint else {
            return nil
        }
        return identity.endpointID
    }

    /// Returns an Iroh endpoint identity scoped to one authenticated app build.
    /// Stable, Nightly, and legacy pairings therefore cannot share control
    /// ownership solely because they expose the same cryptographic endpoint.
    static func scopedIrohEndpointID(
        endpointID: String,
        instanceTag: String?
    ) -> String {
        let normalizedTag = CmxMacAppInstanceIdentity(
            macDeviceID: "",
            instanceTag: instanceTag
        ).instanceTag
        let instanceScope = normalizedTag.map { "tagged:\($0)" } ?? "untagged"
        return "\(instanceScope):\(endpointID)"
    }

    static func macDeviceIDsForLogicalPairedMac(
        _ macDeviceID: String,
        instanceTag: String?,
        in macs: [MobilePairedMac],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> [String] {
        guard let target = macs.first(where: {
            MacPairingKey($0) == MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        }),
              let key = target.scopedDialEndpointKey(supportedKinds: supportedKinds, preferNonLoopback: preferNonLoopback) else {
            return [macDeviceID]
        }
        let matching = macs.filter {
            $0.scopedDialEndpointKey(supportedKinds: supportedKinds, preferNonLoopback: preferNonLoopback) == key
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
            let key = mac.scopedDialEndpointKey(
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

/// Index every stored pairing id to the physical-route alias component it
/// belongs to. Dial endpoints preserve the presentation alias model, while
/// the cryptographic Iroh endpoint joins renamed rows that still compete for
/// one physical control connection. The alias component is scoped by the
/// authenticated app instance, so Stable and Nightly never share a component.
@MainActor
func physicalMacAliasCanonicalIDsByCanonicalID(
    in macs: [MobilePairedMac],
    supportedKinds: [CmxAttachTransportKind],
    preferNonLoopback: Bool
) -> [String: Set<String>] {
    var unionFind = PairedMacAliasUnionFind()
    var pairingIDs: Set<String> = []
    var firstCanonicalIDByDialEndpoint: [String: String] = [:]
    var firstCanonicalIDByIrohEndpoint: [String: String] = [:]

    for mac in macs where !mac.macDeviceID.isEmpty {
        let canonicalID = cmxCanonicalDeviceID(mac.macDeviceID)
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: canonicalID,
            instanceTag: mac.instanceTag
        )
        pairingIDs.insert(pairingID)
        unionFind.insert(pairingID)

        if let dialEndpoint = mac.scopedDialEndpointKey(
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ) {
            if let first = firstCanonicalIDByDialEndpoint[dialEndpoint] {
                unionFind.union(pairingID, first)
            } else {
                firstCanonicalIDByDialEndpoint[dialEndpoint] = pairingID
            }
        }
        if let irohEndpoint = MobileShellComposite.irohEndpointID(
            for: mac,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ) {
            // One physical Iroh endpoint can serve sibling app builds. The
            // endpoint is useful for historical alias repair only within the
            // same authenticated build instance, never across Stable/Nightly.
            let scopedIrohEndpoint = MobileShellComposite.scopedIrohEndpointID(
                endpointID: irohEndpoint,
                instanceTag: mac.instanceTag
            )
            let modeScope = mac.connectionMethodRawValue ?? "default"
            let scopedModeEndpoint = "mode:\(modeScope):\(scopedIrohEndpoint)"
            if let first = firstCanonicalIDByIrohEndpoint[scopedModeEndpoint] {
                unionFind.union(pairingID, first)
            } else {
                firstCanonicalIDByIrohEndpoint[scopedModeEndpoint] = pairingID
            }
        }
    }

    var groupsByRoot: [String: Set<String>] = [:]
    for pairingID in pairingIDs {
        let identity = MobilePairedMac.pairingIdentity(from: pairingID)
        let canonicalID = cmxCanonicalDeviceID(identity.macDeviceID)
        let root = unionFind.root(of: pairingID)
        groupsByRoot[root, default: []].insert(canonicalID)
    }
    var aliasesByCanonicalID: [String: Set<String>] = [:]
    for pairingID in pairingIDs {
        let identity = MobilePairedMac.pairingIdentity(from: pairingID)
        let canonicalID = cmxCanonicalDeviceID(identity.macDeviceID)
        let root = unionFind.root(of: pairingID)
        aliasesByCanonicalID[pairingID] = groupsByRoot[root] ?? [canonicalID]
    }
    return aliasesByCanonicalID
}

private extension MobilePairedMac {
    @MainActor
    func unscopedDialEndpointKey(
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
            preferNonLoopback: preferNonLoopback,
            transportMode: storedTransportMode
        )
        if case let .peer(identity, _)? = reconnectRoutes.first?.endpoint {
            return "iroh:\(identity.endpointID):name:\(displayName.lowercased())"
        }
        guard let (host, port) = MobileShellComposite.firstReconnectHostPortRoute(
            reconnectRoutes,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ), let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            return nil
        }
        return "host:\(normalizedHost.lowercased()):\(port):name:\(displayName.lowercased())"
    }

    @MainActor
    func scopedDialEndpointKey(
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool
    ) -> String? {
        guard let endpointKey = unscopedDialEndpointKey(
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ) else {
            return nil
        }
        let modeScope = connectionMethodRawValue ?? "default"
        return "instance:\(instanceTagScope):mode:\(modeScope):\(endpointKey)"
    }

    /// Presentation coalescing may join historical device ids for one app
    /// instance, but it must never join Stable and Nightly rows that happen to
    /// share a host/port and display name. The stored tag is the build boundary;
    /// an untagged legacy row gets its own conservative scope.
    var instanceTagScope: String {
        let normalizedTag = CmxMacAppInstanceIdentity(
            macDeviceID: "",
            instanceTag: instanceTag
        ).instanceTag
        return normalizedTag.map { "tagged:\($0)" } ?? "untagged"
    }

    /// The device-local mode used when coalescing this pairing's route set.
    /// An absent value deliberately remains a distinct `default` scope so a
    /// later app-wide preference change cannot merge it with an explicit
    /// per-Computer override using a stale endpoint key.
    var storedTransportMode: CmxTransportMode {
        MobileConnectionMethod(rawValue: connectionMethodRawValue ?? "")?.transportMode
            ?? .automatic
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
