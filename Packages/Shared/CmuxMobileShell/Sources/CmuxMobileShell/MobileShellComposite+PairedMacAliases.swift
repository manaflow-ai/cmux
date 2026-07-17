public import CmuxMobilePairedMac
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

    /// Workspace count across every stored id represented by a visible paired-Mac row.
    public func workspaceCount(for macDeviceID: String) -> Int {
        let aliases = Set(pairedMacAliasIDs(for: macDeviceID))
        return workspaces.filter { workspace in
            guard let macDeviceID = workspace.macDeviceID else { return false }
            return aliases.contains(macDeviceID)
        }.count
    }

    /// User customization for every stored id represented by visible paired-Mac rows.
    func pairedMacCustomizationsByAliasID() -> [String: MobilePairedMac] {
        displayPairedMacs.reduce(into: [String: MobilePairedMac]()) { result, mac in
            guard mac.customColor != nil || mac.customIcon != nil else { return }
            for aliasID in pairedMacAliasIDs(for: mac.macDeviceID, instanceTag: mac.instanceTag) {
                result[aliasID] = mac
            }
        }
    }

}
