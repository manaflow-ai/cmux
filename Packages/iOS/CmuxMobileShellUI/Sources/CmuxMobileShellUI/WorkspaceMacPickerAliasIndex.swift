import CmuxMobilePairedMac

struct WorkspaceMacPickerAliasIndex {
    static let empty = WorkspaceMacPickerAliasIndex()

    private let representativeByAliasID: [String: String]
    private let deviceAliasesByEntryID: [String: Set<String>]

    private init() {
        representativeByAliasID = [:]
        deviceAliasesByEntryID = [:]
    }

    init(displayPairedMacs: [MobilePairedMac], aliasesFor: (String) -> [String]) {
        var representativeByAliasID: [String: String] = [:]
        var deviceAliasesByEntryID: [String: Set<String>] = [:]
        let preferredMacs = displayPairedMacs.filter(\.isActive)
            + displayPairedMacs.filter { !$0.isActive }

        for mac in preferredMacs {
            let pairingID = mac.id
            var aliases = Set(aliasesFor(mac.macDeviceID))
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

    func representativeID(for id: String) -> String {
        representativeByAliasID[id] ?? id
    }

    /// The preferred pairing entry that represents the physical device owning
    /// `id`, or the original device id when no pairing exists.
    func deviceRepresentativeID(for id: String) -> String {
        let identity = MobilePairedMac.pairingIdentity(from: id)
        return representativeByAliasID[identity.macDeviceID] ?? identity.macDeviceID
    }

    func filterMachineIDs(for id: String) -> Set<String> {
        if let aliases = deviceAliasesByEntryID[id] {
            return aliases
        }
        let representativeID = deviceRepresentativeID(for: id)
        return deviceAliasesByEntryID[representativeID]
            ?? [MobilePairedMac.pairingIdentity(from: id).macDeviceID]
    }
}
