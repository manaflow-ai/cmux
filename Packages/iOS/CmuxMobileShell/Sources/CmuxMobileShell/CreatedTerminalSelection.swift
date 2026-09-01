import CMUXMobileCore
import CmuxMobileShellModel

func createdTerminalDeviceIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (normalizedCreatedTerminalIdentity(lhs), normalizedCreatedTerminalIdentity(rhs)) {
    case let (lhs?, rhs?):
        return cmxCanonicalDeviceID(lhs) == cmxCanonicalDeviceID(rhs)
    default:
        return false
    }
}

private func normalizedCreatedTerminalIdentity(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return nil
    }
    return value
}

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
        macDeviceID = normalizedCreatedTerminalIdentity(workspace.macDeviceID)
            ?? normalizedCreatedTerminalIdentity(fallbackMacDeviceID)
        macInstanceTag = normalizedCreatedTerminalIdentity(workspace.macInstanceTag)
            ?? normalizedCreatedTerminalIdentity(fallbackInstanceTag)
        self.terminalID = terminalID
    }

    func matches(
        workspace: MobileWorkspacePreview,
        allowsAnonymousForeground: Bool
    ) -> Bool {
        guard workspace.rpcWorkspaceID == remoteWorkspaceID else {
            return false
        }
        switch (normalizedCreatedTerminalIdentity(macDeviceID), normalizedCreatedTerminalIdentity(workspace.macDeviceID)) {
        case (nil, nil):
            guard allowsAnonymousForeground else { return false }
        case let (expected?, actual?):
            guard createdTerminalDeviceIDsMatch(expected, actual) else {
                return false
            }
        case (_, nil):
            // A converging anonymous foreground row can temporarily omit the
            // device id, but only the caller can prove that this is that row.
            guard allowsAnonymousForeground else { return false }
        default:
            return false
        }
        // A snapshot may omit the instance tag while the host is still
        // converging. A pinned tag remains authoritative, so a legacy/untagged
        // sibling cannot match accidentally while its owner is unknown.
        let expectedTag = normalizedCreatedTerminalIdentity(macInstanceTag)
        let actualTag = normalizedCreatedTerminalIdentity(workspace.macInstanceTag)
        if let expectedTag {
            guard actualTag == expectedTag else { return false }
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
        guard normalizedCreatedTerminalIdentity(self.macDeviceID) == nil else { return }
        self.macDeviceID = normalizedCreatedTerminalIdentity(macDeviceID)
        if normalizedCreatedTerminalIdentity(macInstanceTag) == nil {
            self.macInstanceTag = normalizedCreatedTerminalIdentity(instanceTag)
        }
    }

    /// Learn a tag that was resolved after creation without replacing an
    /// already-owned sibling identity.
    mutating func adoptMacInstanceTagIfMissing(_ instanceTag: String) {
        guard normalizedCreatedTerminalIdentity(macInstanceTag) == nil else { return }
        macInstanceTag = normalizedCreatedTerminalIdentity(instanceTag)
    }
}
