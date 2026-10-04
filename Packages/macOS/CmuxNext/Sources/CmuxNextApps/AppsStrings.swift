import Foundation

/// Strings of the App Store window and app surfaces (Resources/Localizable.xcstrings).
nonisolated enum AppsStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var windowTitle: String { t("store.window.title", "App Store") }
    static var discover: String { t("store.tab.discover", "Discover") }
    static var installed: String { t("store.tab.installed", "Installed") }
    static var search: String { t("store.search", "Search apps") }
    static var allCategories: String { t("store.category.all", "All") }
    static var noMatches: String { t("store.empty.noMatches", "No apps match") }
    static var noneInstalled: String { t("store.empty.noneInstalled", "No apps installed") }
    static var selectApp: String { t("store.empty.select", "Select an app") }
    static var loadFailed: String { t("store.error.load", "Could not load the store") }
    static var prototypeEngine: String { t("store.prototype.label", "Prototype engine") }
    static var prototypeHelp: String {
        t("store.prototype.help", "Apps run in-process in JavaScriptCore. Only first-party and local apps load.")
    }

    static var install: String { t("store.action.install", "Install") }
    static var remove: String { t("store.action.remove", "Remove") }
    static var hide: String { t("store.action.hide", "Hide") }
    static var show: String { t("store.action.show", "Show") }
    static var enabled: String { t("store.action.enabled", "Enabled") }
    static var reload: String { t("store.action.reload", "Reload") }
    static var logs: String { t("store.action.logs", "Logs") }
    static var hideLogs: String { t("store.action.hideLogs", "Hide Logs") }
    static var openRepository: String { t("store.action.repository", "Repository") }
    static var installedBadge: String { t("store.badge.installed", "Installed") }
    static var disabledBadge: String { t("store.badge.disabled", "Disabled") }
    static var localBadge: String { t("store.badge.local", "Local") }

    static var permissions: String { t("store.detail.permissions", "Permissions") }
    static var optionalPermissions: String { t("store.detail.optional", "Optional") }
    static var noPermissions: String { t("store.detail.noPermissions", "No permissions") }
    static var runSandboxed: String { t("store.grants.sandboxed", "Run sandboxed") }
    static var sandboxedHelp: String { t("store.grants.sandboxedHelp", "No network, no integrations, nothing beyond the scopes turned on below.") }
    static var granted: String { t("store.grants.granted", "Allowed") }
    static var versions: String { t("store.detail.versions", "Versions") }
    static var preview: String { t("store.detail.preview", "Preview") }
    static var previewSample: String { t("store.detail.previewSample", "Sample data until installed") }
    static var noPreview: String { t("store.detail.noPreview", "Nothing to preview") }
    static var noLogs: String { t("store.detail.noLogs", "No log lines") }

    static func publisher(_ name: String) -> String {
        String(format: t("store.detail.publisher", "by %@"), name)
    }

    static func requires(_ range: String) -> String {
        String(format: t("store.detail.requires", "API %@"), range)
    }

    static func tier(_ tier: AppStoreTier) -> String {
        switch tier {
        case .firstParty: t("store.tier.firstParty", "First party")
        case .verified: t("store.tier.verified", "Verified")
        case .unverified: t("store.tier.unverified", "Unverified")
        }
    }

    static func category(_ id: String) -> String {
        switch id {
        case "sidebar": t("store.category.sidebar", "Sidebar")
        case "agents": t("store.category.agents", "Agents")
        case "git": t("store.category.git", "Git")
        case "productivity": t("store.category.productivity", "Productivity")
        case "monitoring": t("store.category.monitoring", "Monitoring")
        case "themes": t("store.category.themes", "Themes")
        case "browser": t("store.category.browser", "Browser")
        case "cloud": t("store.category.cloud", "Cloud")
        case "developer-tools": t("store.category.developerTools", "Developer Tools")
        case "fun": t("store.category.fun", "Fun")
        default: id
        }
    }

    static func contribution(_ kind: AppContribution.Kind) -> String {
        switch kind {
        case .sidebarSection: t("store.contribution.section", "Sidebar section")
        case .statusItem: t("store.contribution.statusItem", "Status item")
        case .command: t("store.contribution.command", "Command")
        default: kind.rawValue
        }
    }
}
