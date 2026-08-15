import CmuxMobileShellModel

struct NotificationFeedWorkspaceTarget: Sendable {
    private var rowIDs: Set<MobileWorkspacePreview.ID> = []
    private var exactRowIDsByInstanceTag: [String: Set<MobileWorkspacePreview.ID>] = [:]
    private var owners: Set<MacPairingKey> = []

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
    }

    func rowID(instanceTag: String?) -> MobileWorkspacePreview.ID? {
        if let instanceTag, !instanceTag.isEmpty {
            guard let exactRowIDs = exactRowIDsByInstanceTag[instanceTag],
                  exactRowIDs.count == 1 else { return nil }
            return exactRowIDs.first
        }
        // A legacy device-only notification has no authority to borrow the
        // sole tagged Stable/Nightly workspace. It may resolve only to one
        // untagged legacy owner.
        guard owners.count == 1,
              owners.first?.normalizedInstanceTag == nil,
              rowIDs.count == 1 else { return nil }
        return rowIDs.first
    }
}
