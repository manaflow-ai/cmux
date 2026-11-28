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
        let workspaceMacDeviceID = CreatedTerminalSelection.normalizedIdentity(workspace.macDeviceID)
        macDeviceID = workspaceMacDeviceID
            ?? CreatedTerminalSelection.normalizedIdentity(fallbackMacDeviceID)
        if workspaceMacDeviceID == nil {
            macInstanceTag = CreatedTerminalSelection.normalizedIdentity(workspace.macInstanceTag)
                ?? CreatedTerminalSelection.normalizedIdentity(fallbackInstanceTag)
        } else {
            // A known workspace owner may omit its legacy instance tag. Do not
            // borrow the global foreground tag from a different sibling.
            macInstanceTag = CreatedTerminalSelection.normalizedIdentity(workspace.macInstanceTag)
        }
        self.terminalID = terminalID
    }

    func matches(
        workspace: MobileWorkspacePreview,
        allowsAnonymousForeground: Bool
    ) -> Bool {
        guard workspace.rpcWorkspaceID == remoteWorkspaceID else {
            return false
        }
        switch (CreatedTerminalSelection.normalizedIdentity(macDeviceID), CreatedTerminalSelection.normalizedIdentity(workspace.macDeviceID)) {
        case (nil, nil):
            guard allowsAnonymousForeground else { return false }
        case let (expected?, actual?):
            guard CreatedTerminalSelection.deviceIDsMatch(expected, actual) else {
                return false
            }
        default:
            return false
        }
        // A snapshot may omit the instance tag while the host is still
        // converging. A pinned tag remains authoritative, so a legacy/untagged
        // sibling cannot match accidentally while its owner is unknown.
        let tagAuthority = MobileMacInstanceTagAuthority()
        let expectedTag = tagAuthority.normalize(macInstanceTag)
        let actualTag = tagAuthority.normalize(workspace.macInstanceTag)
        if let expectedTag {
            guard tagAuthority.sameStoredAuthority(expectedTag, actualTag) else { return false }
        } else {
            // A pin without a tag belongs to the legacy/untagged pairing only;
            // a tagged row is a distinct sibling until the pin learns that tag.
            guard actualTag == nil else { return false }
        }
        return true
    }

    /// Returns true when a snapshot has the same remote workspace but is
    /// missing one of the pin's owner fields. A known conflicting owner is
    /// never treated as convergence.
    func identityMetadataIsIncomplete(
        in workspace: MobileWorkspacePreview,
        allowsAnonymousForeground: Bool
    ) -> Bool {
        guard workspace.rpcWorkspaceID == remoteWorkspaceID else { return false }
        let expectedDevice = CreatedTerminalSelection.normalizedIdentity(macDeviceID)
        let actualDevice = CreatedTerminalSelection.normalizedIdentity(workspace.macDeviceID)
        switch (expectedDevice, actualDevice) {
        case let (expected?, actual?):
            guard CreatedTerminalSelection.deviceIDsMatch(expected, actual) else { return false }
        default:
            break
        }
        let tagAuthority = MobileMacInstanceTagAuthority()
        let expectedTag = tagAuthority.normalize(macInstanceTag)
        let actualTag = tagAuthority.normalize(workspace.macInstanceTag)
        if let expectedTag, let actualTag,
           !tagAuthority.sameStoredAuthority(expectedTag, actualTag) {
            return false
        }
        // A pin with no owner metadata is safe to preserve only when the
        // caller has proved this is the unique anonymous foreground row.
        if expectedDevice == nil, expectedTag == nil {
            return allowsAnonymousForeground
        }
        return (expectedDevice == nil) != (actualDevice == nil)
            || (expectedTag == nil) != (actualTag == nil)
    }

    /// A legacy/anonymous workspace row can acquire its stable Mac identity
    /// after the create response. Adopt it without retargeting a pin that
    /// already has an owner.
    mutating func adoptMacDeviceIDIfMissing(_ macDeviceID: String, instanceTag: String? = nil) {
        guard CreatedTerminalSelection.normalizedIdentity(self.macDeviceID) == nil else { return }
        self.macDeviceID = CreatedTerminalSelection.normalizedIdentity(macDeviceID)
        if CreatedTerminalSelection.normalizedIdentity(macInstanceTag) == nil {
            self.macInstanceTag = CreatedTerminalSelection.normalizedIdentity(instanceTag)
        }
    }

    /// Learn a tag that was resolved after creation without replacing an
    /// already-owned sibling identity.
    mutating func adoptMacInstanceTagIfMissing(_ instanceTag: String) {
        guard CreatedTerminalSelection.normalizedIdentity(macInstanceTag) == nil else { return }
        macInstanceTag = CreatedTerminalSelection.normalizedIdentity(instanceTag)
    }
}

extension CreatedTerminalSelection {
    static func deviceIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (CreatedTerminalSelection.normalizedIdentity(lhs), CreatedTerminalSelection.normalizedIdentity(rhs)) {
        case let (lhs?, rhs?):
            return cmxCanonicalDeviceID(lhs) == cmxCanonicalDeviceID(rhs)
        default:
            return false
        }
    }

    static func normalizedIdentity(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

}
