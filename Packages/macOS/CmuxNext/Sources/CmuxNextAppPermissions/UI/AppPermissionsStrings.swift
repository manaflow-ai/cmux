import Foundation

/// Strings of the permission surfaces (Resources/Localizable.xcstrings).
/// Few labels: risk tone and position carry most of the meaning.
nonisolated enum AppPermissionsStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static func tier(_ tier: AppTier) -> String {
        switch tier {
        case .firstParty: t("tier.firstParty", "Built in")
        case .verified: t("tier.verified", "Verified")
        case .unverified: t("tier.unverified", "Unverified")
        }
    }

    static var unverifiedWarning: String { t("tier.unverified.warning", "Not reviewed by cmux. Only install apps you trust.") }

    static func profile(_ profile: AppSandboxProfile) -> String {
        switch profile {
        case .standard: t("profile.standard", "Standard")
        case .contained: t("profile.contained", "Contained")
        case .completeSandbox: t("profile.completeSandbox", "Complete sandbox")
        }
    }

    static func profileDetail(_ profile: AppSandboxProfile) -> String {
        switch profile {
        case .standard: t("profile.standard.detail", "Uses what you allow below.")
        case .contained: t("profile.contained.detail", "No files. Asks before network, commands and sending.")
        case .completeSandbox: t("profile.completeSandbox.detail", "No network, no files. Only what you turn on.")
        }
    }

    static var runSandboxed: String { t("profile.runSandboxed", "Run sandboxed") }

    static func approval(_ approval: AppScopeApproval) -> String {
        switch approval {
        case .always: t("approval.always", "Always")
        case .perSession: t("approval.perSession", "Ask once per session")
        case .perCall: t("approval.perCall", "Ask every time")
        case .denied: t("approval.denied", "Off")
        }
    }

    /// Column heads of the capability matrix.
    static func approvalShort(_ approval: AppScopeApproval) -> String {
        switch approval {
        case .always: t("approval.short.always", "Always")
        case .perSession: t("approval.short.perSession", "Session")
        case .perCall: t("approval.short.perCall", "Each time")
        case .denied: t("approval.short.denied", "Off")
        }
    }

    static func axis(_ axis: AppScopeAxis) -> String {
        switch axis {
        case .operations: t("axis.operations", "cmux")
        case .network: t("axis.network", "Network")
        case .files: t("axis.files", "Files")
        case .processes: t("axis.processes", "Commands")
        case .agents: t("axis.agents", "Agents")
        case .clipboard: t("axis.clipboard", "Clipboard")
        case .notifications: t("axis.notifications", "Notifications")
        case .storage: t("axis.storage", "Storage")
        }
    }

    static var optional: String { t("scope.optional", "Asks first") }
    static var restricted: String { t("scope.restricted", "Not available for this app") }
    static var blockedByProfile: String { t("scope.blockedByProfile", "Blocked by the sandbox") }

    static var install: String { t("consent.install", "Install") }
    static var cancel: String { t("consent.cancel", "Cancel") }

    static var folders: String { t("files.title", "Folders") }
    static var addFolder: String { t("files.add", "Add Folder…") }
    static var remove: String { t("files.remove", "Remove") }
    static var noFolders: String { t("files.none", "No folders") }
    static var writable: String { t("files.writable", "Can change files") }

    static var reach: String { t("reach.title", "Reach") }
    static var allWorkspaces: String { t("reach.allWorkspaces", "All workspaces") }
    static var allRooms: String { t("reach.allRooms", "All rooms") }
    static var allMachines: String { t("reach.allMachines", "All machines") }
    static func selectedCount(_ count: Int) -> String { String(format: t("reach.selected", "%lld selected"), count) }

    static var activity: String { t("activity.title", "Activity") }
    static var noActivity: String { t("activity.none", "No calls in the last 7 days") }

    static func result(_ result: AppActivityResult) -> String {
        switch result {
        case .allowed: t("activity.allowed", "Allowed")
        case .asked: t("activity.asked", "Asked")
        case .refused: t("activity.refused", "Refused")
        }
    }

    static var revokeAll: String { t("actions.revokeAll", "Revoke All and Disable") }
    static var removeData: String { t("actions.removeData", "Remove App Data") }
    static var enable: String { t("actions.enable", "Enable") }
    static var disabled: String { t("actions.disabled", "Disabled. Nothing runs until you enable it.") }

    static var allowOnce: String { t("prompt.allowOnce", "Allow Once") }
    static var allow: String { t("prompt.allow", "Allow") }
    static var deny: String { t("prompt.deny", "Deny") }
    static func promptTitle(app: String) -> String { String(format: t("prompt.title", "%@ asks for permission"), app) }
    static var promptSource: String { t("prompt.source", "Shown by cmux") }
}
