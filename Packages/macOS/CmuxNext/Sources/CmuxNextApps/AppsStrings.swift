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
    static var nothingListed: String { t("store.empty.disconnected", "Apps appear when cmux-tui is connected") }
    static var unavailableHelp: String { t("store.disconnected.help", "Nothing can change until then.") }

    /// Why the app supervisor cannot be reached (store banner, app sections).
    static func unavailable(_ reason: AppsUnavailableReason) -> String {
        switch reason {
        case .needsNewerDaemon: t("store.disconnected.needsNewer", "Needs a newer cmux-tui")
        case .notConnected: t("store.disconnected.notConnected", "cmux-tui is not connected")
        }
    }

    static var install: String { t("store.action.install", "Install") }
    static var remove: String { t("store.action.remove", "Remove") }
    static var enabled: String { t("store.action.enabled", "Enabled") }
    static var hide: String { t("store.action.hide", "Hide") }
    static var show: String { t("store.action.show", "Show") }
    static var logs: String { t("store.action.logs", "Logs") }
    static var hideLogs: String { t("store.action.hideLogs", "Hide Logs") }
    static var openRepository: String { t("store.action.repository", "Repository") }
    static var installedBadge: String { t("store.badge.installed", "Installed") }
    static var disabledBadge: String { t("store.badge.disabled", "Disabled") }
    static var localBadge: String { t("store.badge.local", "Local") }
    static var hiddenBadge: String { t("store.badge.hidden", "Hidden") }
    static var installedForEveryone: String { t("store.badge.default", "Installed for everyone") }
    static var installedForEveryoneHelp: String {
        t("store.badge.defaultHelp", "cmux installs this app for everyone. You can disable or hide it and revoke its scopes.")
    }
    static var defaultScopesNote: String { t("store.grants.defaultNote", "Granted for everyone. Revoke any scope below.") }
    static var crashed: String { t("store.host.crashed", "The app stopped unexpectedly") }

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

    static func implementation(_ implementation: AppImplementation) -> String {
        switch implementation.interface {
        case AppImplementation.section: t("store.contribution.section", "Sidebar section")
        case AppImplementation.status: t("store.contribution.statusItem", "Status item")
        default: implementation.interface
        }
    }
}
