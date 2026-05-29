import CmuxSettings
import Foundation

enum SidebarWorkspaceDetailDefaults {
    static let showBranchDirectoryKey = "sidebarShowBranchDirectory"
    static let showPullRequestsKey = "sidebarShowPullRequest"
    static let watchGitStatusKey = "sidebarWatchGitStatus"
    static let showSSHKey = "sidebarShowSSH"
    static let showPortsKey = "sidebarShowPorts"
    static let showLogKey = "sidebarShowLog"
    static let showProgressKey = "sidebarShowProgress"
    static let showCustomMetadataKey = "sidebarShowStatusPills"

    static let showBranchDirectory = true
    static let showPullRequests = true
    static let watchGitStatus = true
    static let showSSH = true
    static let showPorts = true
    static let showLog = true
    static let showProgress = true
    static let showCustomMetadata = true
}

enum SidebarWorkspaceTitleWrapSettings {
    static let key = "sidebarWrapWorkspaceTitles"
    static let defaultWrap = false

    static func wraps(defaults: UserDefaults = .standard) -> Bool {
        SidebarWorkspaceDetailDefaults.boolValue(
            defaults: defaults,
            key: key,
            defaultValue: defaultWrap
        )
    }
}

extension SidebarWorkspaceDetailDefaults {
    static func boolValue(defaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    static func showPullRequestsValue(defaults: UserDefaults) -> Bool {
        boolValue(defaults: defaults, key: showPullRequestsKey, defaultValue: showPullRequests)
    }

    static func watchGitStatusValue(defaults: UserDefaults) -> Bool {
        boolValue(defaults: defaults, key: watchGitStatusKey, defaultValue: watchGitStatus)
    }
}

enum AutomationSettings {
    static let portBaseKey = "cmuxPortBase"
    static let portRangeKey = "cmuxPortRange"
    static let defaultPortBase = 9100
    static let defaultPortRange = 10
}

extension CmuxSettingsFileStore {
    // Keep this in sync with the parser below and the web schema/docs. Settings UI rows
    // validate against this set so new persisted settings need an explicit cmux.json review.
    static var supportedSettingsJSONPaths: Set<String> {
        CmuxSettingsCatalog.supportedJSONPaths
    }
}
