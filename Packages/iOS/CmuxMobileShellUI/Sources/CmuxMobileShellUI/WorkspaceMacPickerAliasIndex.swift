import CmuxMobilePairedMac

struct WorkspaceMacPickerAliasIndex {
    static let empty = WorkspaceMacPickerAliasIndex()

    private let representativeByAliasID: [String: String]
    private let deviceAliasesByEntryID: [String: Set<String>]

    private init() {
        representativeByAliasID = [:]
        deviceAliasesByEntryID = [:]
    }

    init(
        displayPairedMacs: [MobilePairedMac],
        aliasesFor: (String, String?) -> [String]
    ) {
        var representativeByAliasID: [String: String] = [:]
        var deviceAliasesByEntryID: [String: Set<String>] = [:]
        let preferredMacs = displayPairedMacs.filter(\.isActive)
            + displayPairedMacs.filter { !$0.isActive }

        for mac in preferredMacs {
            let pairingID = mac.id
            var aliases = Set(aliasesFor(mac.macDeviceID, mac.instanceTag))
            aliases.insert(mac.macDeviceID)
            deviceAliasesByEntryID[pairingID] = aliases
            for aliasID in aliases {
                if representativeByAliasID[aliasID] == nil {
                    representativeByAliasID[aliasID] = pairingID
                }
            }
        }
        for mac in displayPairedMacs {
            if mac.id != mac.macDeviceID {
                representativeByAliasID[mac.id] = mac.id
            }
        }

        self.representativeByAliasID = representativeByAliasID
        self.deviceAliasesByEntryID = deviceAliasesByEntryID
    }

    init(displayPairedMacs: [MobilePairedMac], aliasesFor: (String) -> [String]) {
        self.init(displayPairedMacs: displayPairedMacs) { deviceID, _ in
            aliasesFor(deviceID)
        }
    }

    func representativeID(for id: String) -> String {
        if let representative = representativeByAliasID[id] {
            return representative
        }
        let identity = MobilePairedMac.pairingIdentity(from: id)
        guard let tag = identity.instanceTag, !tag.isEmpty else {
            return id
        }
        let physicalRepresentative =
            representativeByAliasID[identity.macDeviceID] ?? identity.macDeviceID
        let representativeIdentity = MobilePairedMac.pairingIdentity(
            from: physicalRepresentative
        )
        return MobilePairedMac.pairingID(
            macDeviceID: representativeIdentity.macDeviceID,
            instanceTag: tag
        )
    }

    /// The preferred pairing entry that represents the physical device owning
    /// `id`, or the original device id when no pairing exists.
    func deviceRepresentativeID(for id: String) -> String {
        let identity = MobilePairedMac.pairingIdentity(from: id)
        return representativeByAliasID[identity.macDeviceID] ?? identity.macDeviceID
    }

    func filterMachineIDs(for id: String) -> Set<String> {
        let identity = MobilePairedMac.pairingIdentity(from: id)
        let deviceAliases: Set<String>
        if let aliases = deviceAliasesByEntryID[id] {
            deviceAliases = aliases
        } else {
            let representativeEntryID = representativeID(for: id)
            deviceAliases = deviceAliasesByEntryID[representativeEntryID]
                ?? [identity.macDeviceID]
        }
        // A tagged selection filters to that build's rows: emit pairing-id
        // entries per device alias (legacy nil-tag rows still match them in
        // MobileWorkspaceListFilter). An untagged selection stays device-level.
        guard let tag = identity.instanceTag, !tag.isEmpty else { return deviceAliases }
        return Set(deviceAliases.map {
            MobilePairedMac.pairingID(macDeviceID: $0, instanceTag: tag)
        })
    }
}
