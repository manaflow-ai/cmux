import Foundation

/// Strings of the App Store window and app surfaces (Resources/Localizable.xcstrings).
nonisolated enum AppsStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var windowTitle: String { t("store.window.title", "App Store") }
    /// An app mount failed and the supervisor gave no reason.
    static var mountFailed: String { t("apps.mount.failed", "The app could not start") }
    static var discover: String { t("store.tab.discover", "Discover") }
    static var installed: String { t("store.tab.installed", "Installed") }
    static var features: String { t("store.tab.features", "Features") }
    static var noFeatureMatches: String { t("store.empty.noFeatureMatches", "No features match") }
    static var get: String { t("store.feature.action.get", "Get") }
    static var featureOn: String { t("store.feature.badge.on", "On") }
    static var featureNotChanged: String { t("store.feature.notChanged", "Not changed") }
    static var featureManaged: String { t("store.feature.managed", "Managed by your organization") }
    static var featureKeptOn: String { t("store.feature.keptOn", "Your organization recommends this, so it stays on") }
    static func featureSetting(_ key: String) -> String { String(format: t("store.feature.setting", "Setting: %@"), key) }
    static var featureSettingsLink: String { t("store.feature.settingsLink", "Settings…") }
    static func featureSettingsHelp(_ name: String) -> String { String(format: t("store.feature.settingsLink.help", "Open %@ in Settings"), name) }

    /// A Features tab category chip.
    static func featureCategory(_ category: AppFeature.Category) -> String {
        switch category {
        case .backgrounds: t("store.feature.category.backgrounds", "Backgrounds")
        case .appearance: t("store.feature.category.appearance", "Appearance")
        case .chief: t("store.feature.category.chief", "Chief")
        case .newTab: t("store.feature.category.newTab", "New Tab")
        case .sidebar: t("store.feature.category.sidebar", "Sidebar")
        case .media: t("store.feature.category.media", "Media")
        case .editor: t("store.feature.category.editor", "Editor")
        case .devices: t("store.feature.category.devices", "Mac & Phone")
        case .browser: t("store.feature.category.browser", "Browser")
        case .layout: t("store.feature.category.layout", "Layout")
        }
    }
    static var search: String { t("store.search", "Search apps") }
    static var searchFeatures: String { t("store.search.features", "Search features") }
    static var allCategories: String { t("store.category.all", "All") }
    static var noMatches: String { t("store.empty.noMatches", "No apps match") }
    static var noneInstalled: String { t("store.empty.noneInstalled", "No apps installed") }
    static var selectApp: String { t("store.empty.select", "Select an app") }
    static func unknownApp(_ id: String) -> String { String(format: t("apps.client.unknownApp", "No app %@"), id) }
    static var unavailableHelp: String { t("apps.store.disconnected.help", "Nothing can change until then.") }

    private static var notConnected: String { t("apps.store.disconnected.notConnected", "cmux-tui is not connected") }

    /// Why the app supervisor cannot be reached (store banner, app sections).
    static func unavailable(_ reason: AppsUnavailableReason) -> String {
        switch reason {
        case .needsNewerDaemon: t("apps.store.disconnected.needsNewer", "Needs a newer cmux-tui")
        case .notConnected: notConnected
        case .notReady(let cause): "\(notConnected): \(cause)"
        case .turnedOff(let reason): reason
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
    static var cloudFeatureEyebrow: String { t("store.cloud.eyebrow", "Featured") }
    static var cloudFeatureTitle: String { t("store.cloud.title", "Cloud Machines") }
    static var cloudFeatureBody: String {
        t("store.cloud.body", "Run agents, builds and tests on your own machine in the cloud. Your Mac stays quick, and the work goes on while it sleeps.")
    }
    static var cloudFeatureOpen: String { t("store.cloud.open", "Explore Cloud") }
    static var installedBadge: String { t("store.badge.installed", "Installed") }
    static var disabledBadge: String { t("store.badge.disabled", "Disabled") }
    static var localBadge: String { t("store.badge.local", "Local") }
    static var hiddenBadge: String { t("apps.store.badge.hidden", "Hidden") }
    static var installedForEveryone: String { t("apps.store.badge.default", "Installed for everyone") }
    static var installedForEveryoneHelp: String {
        t("apps.store.badge.defaultHelp", "cmux installs this app for everyone. You can disable or hide it and revoke its scopes.")
    }
    static var defaultScopesNote: String { t("apps.store.grants.defaultNote", "Granted for everyone. Revoke any scope below.") }
    static var crashed: String { t("apps.store.host.crashed", "The app stopped unexpectedly") }

    static var permissions: String { t("store.detail.permissions", "Permissions") }
    static var optionalPermissions: String { t("store.detail.optional", "Optional") }
    static var noPermissions: String { t("store.detail.noPermissions", "No permissions") }
    static var runSandboxed: String { t("store.grants.sandboxed", "Run sandboxed") }
    static var sandboxedHelp: String { t("store.grants.sandboxedHelp", "No network, no integrations, nothing beyond the scopes turned on below.") }
    static var granted: String { t("store.grants.granted", "Allowed") }
    static var versions: String { t("store.detail.versions", "Versions") }
    static var preview: String { t("store.detail.preview", "Preview") }
    static var noLogs: String { t("store.detail.noLogs", "No log lines") }
    static var previewSample: String { t("apps.store.detail.previewSample", "Sample data until installed") }
    static var noPreview: String { t("apps.store.detail.noPreview", "Nothing to preview") }
    static var removed: String { t("store.action.removed", "Removed") }
    static var undo: String { t("store.action.undo", "Undo") }

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
