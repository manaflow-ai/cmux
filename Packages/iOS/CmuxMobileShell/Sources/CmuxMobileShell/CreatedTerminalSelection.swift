import CmuxMobileShellModel

struct CreatedTerminalSelection: Equatable {
    var remoteWorkspaceID: MobileWorkspacePreview.ID
    var macDeviceID: String?
    var terminalID: MobileTerminalPreview.ID

    init(workspace: MobileWorkspacePreview, terminalID: MobileTerminalPreview.ID) {
        remoteWorkspaceID = workspace.rpcWorkspaceID
        macDeviceID = workspace.macDeviceID.flatMap { $0.isEmpty ? nil : $0 }
        self.terminalID = terminalID
    }

    func matches(workspace: MobileWorkspacePreview) -> Bool {
        guard workspace.rpcWorkspaceID == remoteWorkspaceID else { return false }
        return workspace.macDeviceID.flatMap { $0.isEmpty ? nil : $0 } == macDeviceID
    }

    mutating func adoptMacDeviceID(_ macDeviceID: String) { self.macDeviceID = macDeviceID.isEmpty ? nil : macDeviceID }
}
