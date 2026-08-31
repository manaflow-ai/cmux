import CMUXMobileCore
import CmuxMobileShellModel

/// Keeps a terminal created by the user selected while workspace snapshots
/// catch up with the Mac. The UI row id is not stable across multi-Mac
/// aggregation, so the pin is owned by the remote workspace and Mac identity.
struct CreatedTerminalSelection: Equatable {
    var remoteWorkspaceID: MobileWorkspacePreview.ID
    var macDeviceID: String?
    var macInstanceTag: String?
    var terminalID: MobileTerminalPreview.ID

    init(
        workspace: MobileWorkspacePreview,
        fallbackMacDeviceID: String? = nil,
        fallbackInstanceTag: String? = nil,
        terminalID: MobileTerminalPreview.ID
    ) {
        remoteWorkspaceID = workspace.rpcWorkspaceID
        macDeviceID = Self.normalized(workspace.macDeviceID) ?? Self.normalized(fallbackMacDeviceID)
        macInstanceTag = Self.normalized(workspace.macInstanceTag) ?? Self.normalized(fallbackInstanceTag)
        self.terminalID = terminalID
    }

    func matches(workspace: MobileWorkspacePreview) -> Bool {
        guard workspace.rpcWorkspaceID == remoteWorkspaceID,
              Self.deviceIDsMatch(macDeviceID, workspace.macDeviceID) else {
            return false
        }
        return Self.normalized(macInstanceTag) == Self.normalized(workspace.macInstanceTag)
    }

    /// A legacy/anonymous workspace row can acquire its stable Mac identity
    /// after the create response. Adopt it without retargeting a pin that
    /// already has an owner.
    mutating func adoptMacDeviceIDIfMissing(_ macDeviceID: String, instanceTag: String? = nil) {
        guard Self.normalized(self.macDeviceID) == nil else { return }
        self.macDeviceID = Self.normalized(macDeviceID)
        if Self.normalized(macInstanceTag) == nil {
            self.macInstanceTag = Self.normalized(instanceTag)
        }
    }

    static func deviceIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (normalized(lhs), normalized(rhs)) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return cmxCanonicalDeviceID(lhs) == cmxCanonicalDeviceID(rhs)
        default:
            return false
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
