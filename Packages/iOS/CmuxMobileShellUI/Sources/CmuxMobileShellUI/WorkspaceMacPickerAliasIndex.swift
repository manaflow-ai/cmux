import CmuxMobilePairedMac

struct WorkspaceMacPickerAliasIndex {
    static let empty = WorkspaceMacPickerAliasIndex()

    private let representativeByAliasID: [String: String]
    private let aliasesByRepresentativeID: [String: Set<String>]

    private init() {
        representativeByAliasID = [:]
        aliasesByRepresentativeID = [:]
    }

    init(displayPairedMacs: [MobilePairedMac], aliasesFor: (String) -> [String]) {
        var representativeByAliasID: [String: String] = [:]
        var aliasesByRepresentativeID: [String: Set<String>] = [:]

        for mac in displayPairedMacs {
            let representativeID = mac.macDeviceID
            var aliases = Set(aliasesFor(representativeID))
            aliases.insert(representativeID)
            aliasesByRepresentativeID[representativeID] = aliases
            for aliasID in aliases {
                representativeByAliasID[aliasID] = representativeID
            }
        }

        self.representativeByAliasID = representativeByAliasID
        self.aliasesByRepresentativeID = aliasesByRepresentativeID
    }

    func representativeID(for id: String) -> String {
        representativeByAliasID[id] ?? id
    }

    func filterMachineIDs(for id: String) -> Set<String> {
        let representativeID = representativeID(for: id)
        return aliasesByRepresentativeID[representativeID] ?? [representativeID]
    }
}
