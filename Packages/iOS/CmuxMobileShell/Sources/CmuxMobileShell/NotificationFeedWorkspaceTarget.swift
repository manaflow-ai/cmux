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
        let owner = MacPairingKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        if let instanceTag = owner.normalizedInstanceTag {
            exactRowIDsByInstanceTag[instanceTag, default: []].insert(rowID)
        }
        owners.insert(owner)
    }

    func rowID(instanceTag: String?) -> MobileWorkspacePreview.ID? {
        if let instanceTag = MacPairingKey(
            macDeviceID: "",
            instanceTag: instanceTag
        ).normalizedInstanceTag {
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
