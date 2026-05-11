import CMUXSettingsCore

enum SidebarWorkspaceDetailDefaults {
    static let showBranchDirectory = true
    static let showPullRequests = true
    static let showSSH = true
    static let showPorts = true
    static let showLog = true
    static let showProgress = true
    static let showCustomMetadata = true
}

enum AutomationSettings {
    static let portBaseKey = "cmuxPortBase"
    static let portRangeKey = "cmuxPortRange"
    static let defaultPortBase = 9100
    static let defaultPortRange = 10
}

extension CmuxSettingsFileStore {
    static let supportedSettingsJSONPaths: Set<String> = CmuxSettingsRegistry.supportedSettingsJSONPaths
}
