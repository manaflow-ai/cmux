import CmuxMobileShellModel

struct NotificationFeedWorkspaceTarget: Sendable {
    private var rowIDs: Set<MobileWorkspacePreview.ID> = []
    private var exactRowIDsByInstanceTag: [String: Set<MobileWorkspacePreview.ID>] = [:]
    private var owners: Set<MacPairingKey> = []
    private var ownerDevices: Set<String> = []

    mutating func insert(
        rowID: MobileWorkspacePreview.ID,
        macDeviceID: String,
        instanceTag: String?
    ) {
        rowIDs.insert(rowID)
        if let instanceTag, !instanceTag.isEmpty {
            exactRowIDsByInstanceTag[instanceTag, default: []].insert(rowID)
        }
        let owner = MacPairingKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        owners.insert(owner)
        ownerDevices.insert(owner.canonicalMacDeviceID)
    }

    func rowID(instanceTag: String?) -> MobileWorkspacePreview.ID? {
        if let instanceTag, !instanceTag.isEmpty {
            guard let exactRowIDs = exactRowIDsByInstanceTag[instanceTag],
                  exactRowIDs.count == 1 else { return nil }
            return exactRowIDs.first
        }
        guard owners.count <= ownerDevices.count, rowIDs.count == 1 else { return nil }
        return rowIDs.first
    }
}
