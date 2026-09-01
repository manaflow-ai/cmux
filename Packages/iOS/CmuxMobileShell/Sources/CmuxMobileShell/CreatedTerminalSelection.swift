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

    func matches(
        workspace: MobileWorkspacePreview,
        allowsAnonymousForeground: Bool
    ) -> Bool {
        guard workspace.rpcWorkspaceID == remoteWorkspaceID else {
            return false
        }
        switch (Self.normalized(macDeviceID), Self.normalized(workspace.macDeviceID)) {
        case (nil, nil):
            guard allowsAnonymousForeground else { return false }
        case let (expected?, actual?):
            guard cmxCanonicalDeviceID(expected) == cmxCanonicalDeviceID(actual) else {
                return false
            }
        default:
            return false
        }
        // A snapshot may omit the instance tag while the host is still
        // converging. A present tag remains authoritative, so sibling builds
        // cannot match accidentally; an absent tag is simply unknown.
        let expectedTag = Self.normalized(macInstanceTag)
        let actualTag = Self.normalized(workspace.macInstanceTag)
        if let expectedTag {
            guard actualTag == nil || expectedTag == actualTag else { return false }
        } else {
            // A pin without a tag belongs to the legacy/untagged pairing only;
            // a tagged row is a distinct sibling until the pin learns that tag.
            guard actualTag == nil else { return false }
        }
        return true
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

    /// Learn a tag that was resolved after creation without replacing an
    /// already-owned sibling identity.
    mutating func adoptMacInstanceTagIfMissing(_ instanceTag: String) {
        guard Self.normalized(macInstanceTag) == nil else { return }
        macInstanceTag = Self.normalized(instanceTag)
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
