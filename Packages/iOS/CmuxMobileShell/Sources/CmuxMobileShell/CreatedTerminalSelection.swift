import CmuxMobileShellModel

struct CreatedTerminalSelection: Equatable {
    var remoteWorkspaceID: MobileWorkspacePreview.ID
    var macDeviceID: String?
    var terminalID: MobileTerminalPreview.ID

    init(workspace: MobileWorkspacePreview, terminalID: MobileTerminalPreview.ID) {
        remoteWorkspaceID = workspace.rpcWorkspaceID
        macDeviceID = Self.normalizedMacDeviceID(workspace.macDeviceID)
        self.terminalID = terminalID
    }

    func matches(workspace: MobileWorkspacePreview) -> Bool {
        guard workspace.rpcWorkspaceID == remoteWorkspaceID else { return false }
        return Self.normalizedMacDeviceID(workspace.macDeviceID) == macDeviceID
    }

    mutating func adoptMacDeviceID(_ macDeviceID: String) { self.macDeviceID = Self.normalizedMacDeviceID(macDeviceID) }

    private static func normalizedMacDeviceID(_ macDeviceID: String?) -> String? {
        guard let macDeviceID, !macDeviceID.isEmpty else { return nil }
        return macDeviceID
    }
}
