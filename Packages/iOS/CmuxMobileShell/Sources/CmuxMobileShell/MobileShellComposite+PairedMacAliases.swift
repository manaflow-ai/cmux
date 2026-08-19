public import CmuxMobilePairedMac
internal import CMUXMobileCore
internal import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    /// Presentation-only duplicate collapse for the Computers screen.
    public var displayPairedMacs: [MobilePairedMac] {
        Self.coalescePairedMacsByDialEndpoint(
            pairedMacs,
            supportedKinds: runtime?.supportedRouteKinds ?? [],
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
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
        if let aliases = pairedMacAliasIDsByRepresentativeID.first(where: {
            let identity = MobilePairedMac.pairingIdentity(from: $0.key)
            return macInstanceTagAuthority.sameStoredAuthority(
                identity.instanceTag,
                instanceTag
            ) && $0.value.contains(where: {
                cmxCanonicalDeviceID($0) == cmxCanonicalDeviceID(macDeviceID)
            })
        })?.value {
            return aliases
        }
        return [cmxCanonicalDeviceID(macDeviceID)]
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
                presenceMap.soleInstanceSummary(deviceId: $0)
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

    /// Workspace count for one exact pairing row. A legacy untagged workspace
    /// belongs only to the legacy untagged pairing, because there is no build
    /// authority that permits attributing it to Stable or Nightly.
    public func workspaceCount(for macDeviceID: String, instanceTag: String? = nil) -> Int {
        let aliases = Set(pairedMacAliasIDs(for: macDeviceID, instanceTag: instanceTag))
        return workspaces.filter { workspace in
            guard let rowDeviceID = workspace.macDeviceID else { return false }
            guard aliases.contains(rowDeviceID) else { return false }
            return macInstanceTagAuthority.sameStoredAuthority(
                workspace.macInstanceTag,
                instanceTag
            )
        }.count
    }

    /// User customization for every stored id represented by visible paired-Mac rows.
    ///
    /// Workspaces are stamped with their owning instance tag, so customizations
    /// stay on the exact Stable/Nightly pairing instead of leaking across a
    /// shared physical device id.
    func pairedMacCustomizationsByAliasID() -> [String: MobilePairedMac] {
        Self.customizationsByAliasID(for: displayPairedMacs) { mac in
            pairedMacAliasIDs(for: mac.macDeviceID, instanceTag: mac.instanceTag)
                .map { aliasID in
                    MobilePairedMac.pairingID(
                        macDeviceID: aliasID,
                        instanceTag: mac.instanceTag
                    )
                }
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
