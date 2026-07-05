import CmuxMobileShellModel

struct CreatedTerminalSelection: Equatable {
    var remoteWorkspaceID: MobileWorkspacePreview.ID
    var macDeviceID: MacDeviceID
    var terminalID: MobileTerminalPreview.ID

    init(workspace: MobileWorkspacePreview, terminalID: MobileTerminalPreview.ID) {
        remoteWorkspaceID = workspace.rpcWorkspaceID
        macDeviceID = MacDeviceID(workspace.macDeviceID)
        self.terminalID = terminalID
    }

    func matches(workspace: MobileWorkspacePreview) -> Bool {
        guard workspace.rpcWorkspaceID == remoteWorkspaceID else { return false }
        return MacDeviceID(workspace.macDeviceID) == macDeviceID
    }

    mutating func adoptMacDeviceIDIfMissing(_ macDeviceID: String) {
        guard self.macDeviceID.rawValue == nil else { return }
        self.macDeviceID = MacDeviceID(macDeviceID)
    }
}
