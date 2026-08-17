public import CmuxMobilePairedMac
internal import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    /// Presentation-only duplicate collapse for the Computers screen.
    public var displayPairedMacs: [MobilePairedMac] {
        if deviceListMustFailClosed {
            return []
        }
        let source = authoritativeSyncedPairedMacs ?? pairedMacs
        return Self.coalescePairedMacsByDialEndpoint(
            source,
            supportedKinds: runtime?.supportedRouteKinds ?? [],
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
    }

    /// Project the authoritative DO device rows into the existing paired-Mac
    /// value model used by the picker and Computers screen. Rows absent from
    /// the projection are intentionally omitted, so a Mac that signed out
    /// disappears from every discoverability surface immediately. Local
    /// customizations are retained when a matching paired row exists.
    private var authoritativeSyncedPairedMacs: [MobilePairedMac]? {
        guard deviceListLocalFirst,
              let authoritativeTeam = deviceListAuthoritativeTeamID,
              authoritativeTeam == deviceListRenderedTeamID else {
            return nil
        }
        let existingByAuthority = pairedMacs.reduce(
            into: [MacPairingKey: MobilePairedMac]()
        ) { result, mac in
            // Preserve the first row just as the previous linear search did,
            // while making each device-instance lookup constant time.
            result[MacPairingKey(mac)] = result[MacPairingKey(mac)] ?? mac
        }
        return registryDevices.flatMap { device in
            guard !device.deviceId.isEmpty else { return [MobilePairedMac]() }
            return device.instances.compactMap { instance in
                let existing = existingByAuthority[
                    MacPairingKey(
                        macDeviceID: device.deviceId,
                        instanceTag: instance.tag
                    )
                ]
                return MobilePairedMac(
                    macDeviceID: device.deviceId,
                    displayName: device.displayName,
                    routes: instance.routes,
                    // The authoritative record supplies a stable fallback for
                    // new rows. `Date()` here would change the identity value on
                    // every observation and make the projection look mutated.
                    createdAt: existing?.createdAt ?? instance.lastSeenAt,
                    lastSeenAt: instance.lastSeenAt,
                    isActive: connectedMacDeviceID == device.deviceId
                        && macInstanceTagAuthority.sameStoredAuthority(
                            connectedMacInstanceTag,
                            instance.tag
                        ),
                    stackUserID: existing?.stackUserID ?? identityProvider?.currentUserID,
                    teamID: authoritativeTeam,
                    customName: existing?.customName,
                    customColor: existing?.customColor,
                    customIcon: existing?.customIcon,
                    instanceTag: instance.tag,
                    legacyTailscaleRoutes: existing?.legacyTailscaleRoutes
                )
            }
        }
    }

    /// Build-channel labels for the computer pickers, keyed by pairing entry
    /// id, resolved with the same priority as the Computers sheet badge: live
    /// presence first, then the stored instance tag while offline.
    public func pairedMacBuildLabelsByEntryID() -> [String: String] {
        Self.buildLabelsByEntryID(for: displayPairedMacs) { macDeviceID, instanceTag in
            presenceSummary(for: macDeviceID, instanceTag: instanceTag)?.buildLabel
        }
    }

    /// Shared label derivation for store-backed pickers and store-free
    /// DEBUG fixtures (which pass a lookup that always returns `nil`).
    public static func buildLabelsByEntryID(
        for macs: [MobilePairedMac],
        presenceBuildLabel: (String, String?) -> String?
    ) -> [String: String] {
        macs.reduce(into: [String: String]()) { result, mac in
            result[mac.id] = presenceBuildLabel(mac.macDeviceID, mac.instanceTag)
                ?? MacBuildChannel().label(bundleID: nil, tag: mac.instanceTag)
        }
    }

    /// Stored ids represented by a visible paired-Mac row.
    public func pairedMacAliasIDs(
        for macDeviceID: String,
        instanceTag: String? = nil
    ) -> [String] {
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        if let aliases = pairedMacAliasIDsByRepresentativeID[pairingID] {
            return aliases
        }
        if let aliases = pairedMacAliasIDsByRepresentativeID.values.first(where: {
            $0.contains(macDeviceID)
        }) {
            return aliases
        }
        return [macDeviceID]
    }

    /// Presence across every stored id represented by a visible paired-Mac row.
    /// When `instanceTag` is present, only that tagged app instance contributes.
    public func presenceSummary(
        for macDeviceID: String,
        instanceTag: String? = nil
    ) -> PresenceMap.DeviceSummary? {
        let summaries = pairedMacAliasIDs(for: macDeviceID, instanceTag: instanceTag).compactMap {
            if let instanceTag {
                presenceMap.instanceSummary(deviceId: $0, tag: instanceTag)
            } else {
                presenceMap.deviceSummary(deviceId: $0)
            }
        }
        guard !summaries.isEmpty else { return nil }
        let online = summaries.contains(where: \.online)
        let freshest = summaries.max { $0.lastSeenAt < $1.lastSeenAt }
        let label = summaries.first { $0.online && $0.buildLabel != nil }?.buildLabel
            ?? freshest?.buildLabel
        return PresenceMap.DeviceSummary(
            online: online,
            lastSeenAt: freshest?.lastSeenAt ?? Date(timeIntervalSince1970: 0),
            buildLabel: label
        )
    }

    /// Workspace count for one pairing row. Tagged rows count only toward
    /// their own build; rows with no tag (legacy hosts) count toward every
    /// sibling because their build is unknowable.
    public func workspaceCount(for macDeviceID: String, instanceTag: String? = nil) -> Int {
        let aliases = Set(pairedMacAliasIDs(for: macDeviceID, instanceTag: instanceTag))
        return workspaces.filter { workspace in
            guard let rowDeviceID = workspace.macDeviceID else { return false }
            guard aliases.contains(rowDeviceID) else { return false }
            guard let rowTag = workspace.macInstanceTag, let instanceTag else { return true }
            return macInstanceTagAuthority.sameStoredAuthority(rowTag, instanceTag)
        }.count
    }

    /// User customization for every stored id represented by visible paired-Mac rows.
    ///
    /// Workspaces carry no instance tag, so when sibling builds of one Mac are
    /// both customized the active pairing's customization represents the
    /// device; without that preference the result depended on iteration order.
    func pairedMacCustomizationsByAliasID() -> [String: MobilePairedMac] {
        Self.customizationsByAliasID(for: displayPairedMacs) { mac in
            pairedMacAliasIDs(for: mac.macDeviceID, instanceTag: mac.instanceTag)
        }
    }

    /// Deterministic alias→customization resolution: the active pairing first,
    /// then remaining display order, first write wins per alias id.
    static func customizationsByAliasID(
        for macs: [MobilePairedMac],
        aliasesFor: (MobilePairedMac) -> [String]
    ) -> [String: MobilePairedMac] {
        let preferredMacs = macs.filter(\.isActive) + macs.filter { !$0.isActive }
        var result: [String: MobilePairedMac] = [:]
        for mac in preferredMacs where mac.customColor != nil || mac.customIcon != nil {
            for aliasID in aliasesFor(mac) where result[aliasID] == nil {
                result[aliasID] = mac
            }
        }
        return result
    }

}
