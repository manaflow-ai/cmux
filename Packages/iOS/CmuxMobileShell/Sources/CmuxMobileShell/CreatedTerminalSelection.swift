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

    static func normalizedMacDeviceID(_ macDeviceID: String?) -> String? {
        macDeviceID.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func macDeviceID(_ lhs: String?, matches rhs: String?) -> Bool {
        normalizedMacDeviceID(lhs) == normalizedMacDeviceID(rhs)
    }

    static func macDeviceID(_ current: String?, matchesPrevious previous: String?, foreground: String?) -> Bool {
        let current = normalizedMacDeviceID(current)
        let previous = normalizedMacDeviceID(previous)
        return current == previous || (previous == nil && current == normalizedMacDeviceID(foreground))
    }

    mutating func adoptMacDeviceID(_ macDeviceID: String) { self.macDeviceID = Self.normalizedMacDeviceID(macDeviceID) }
}
