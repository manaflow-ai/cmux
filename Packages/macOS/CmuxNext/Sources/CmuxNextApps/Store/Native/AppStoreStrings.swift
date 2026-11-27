import Foundation

/// Strings of the native App Store (Resources/Localizable.xcstrings). Most keys are the React store's
/// (the page reads the same table), so both stores say the same words in every language.
nonisolated enum AppStoreStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .localizedModule)
    }

    static var today: String { t("store.tab.today", "Today") }
    static var discover: String { t("store.tab.discover", "Discover") }
    static var categories: String { t("store.tab.categories", "Categories") }
    static var community: String { t("store.tab.community", "Community") }
    static var onOtherDevices: String { t("store.community.onOtherDevices", "On Your Other Devices") }
    static var installOnThisMac: String { t("store.community.installOnThisMac", "Install on This Mac") }
    static var allKinds: String { t("store.category.all", "All") }
    static var kindExtensions: String { t("store.community.kind.extensions", "Extensions") }
    static var kindSetups: String { t("store.community.kind.setups", "Setups") }
    static var kindExtension: String { t("store.community.kind.extension", "Extension") }
    static var kindSetup: String { t("store.community.kind.setup", "Setup") }
    static var kind: String { t("store.community.kind", "Kind") }
    static var sortBy: String { t("store.community.sortBy", "Sort by") }
    static var downloadsLabel: String { t("store.community.downloads", "Downloads") }
    static var lastUpdated: String { t("store.community.lastUpdated", "Last Updated") }
    static var license: String { t("store.community.license", "License") }
    static func downloads(_ count: Int) -> String {
        String(format: t("store.community.downloadCount", "%@ downloads"), count.formatted())
    }
    static func updated(_ date: String) -> String { String(format: t("store.community.updatedOn", "Updated %@"), date) }

    /// A community sort's name.
    static func communitySort(_ sort: String) -> String {
        switch sort {
        case "downloads": t("store.community.sort.downloads", "Most Downloaded")
        case "updated": t("store.community.sort.updated", "Recently Updated")
        case "stars": t("store.community.sort.stars", "Most Stars")
        case "name": t("store.community.sort.name", "Name")
        default: featured
        }
    }
    static var updates: String { t("store.updates.title", "Updates") }
    static var installed: String { t("store.tab.installed", "Installed") }
    static var search: String { t("store.search", "Search apps") }

    static var install: String { t("store.action.install", "Install") }
    static var open: String { t("store.action.open", "Open") }
    static var hide: String { t("store.action.hide", "Hide") }
    static var show: String { t("store.action.show", "Show") }
    static var remove: String { t("store.action.remove", "Remove") }
    static var update: String { t("store.action.update", "Update") }
    static var updateAll: String { t("store.updates.updateAll", "Update All") }
    static var retry: String { t("store.action.retry", "Retry") }
    static var repository: String { t("store.action.repository", "Repository") }

    static var featured: String { t("store.browse.featured", "Featured") }
    static var allApps: String { t("store.browse.allApps", "All apps") }
    static var newAndUpdated: String { t("store.today.newAndUpdated", "New and Updated") }
    static var topApps: String { t("store.section.top", "Top Apps") }

    static var free: String { t("store.detail.free", "Free") }
    static var showsUpIn: String { t("store.detail.showsUpIn", "Shows up in") }
    static var permissions: String { t("store.detail.permissions", "Permissions") }
    static var noPermissions: String { t("store.detail.noPermissions", "Needs no special access") }
    static var optional: String { t("store.detail.optional", "Optional") }
    static var information: String { t("store.detail.information", "Information") }
    static var developer: String { t("store.detail.developer", "Developer") }
    static var category: String { t("store.detail.category", "Category") }
    static var version: String { t("store.detail.version", "Version") }
    static var runsOn: String { t("store.detail.runsOn", "Runs on") }
    static var whatsNew: String { t("store.detail.whatsNew", "What's New") }
    static var versionHistory: String { t("store.detail.versionHistory", "Version History") }
    static var loading: String { t("store.detail.loading", "Loading…") }
    static var notFound: String { t("store.detail.notFound", "App not found") }
    static var notInStore: String { t("store.notice.notInStore", "That app isn't in the store") }
    static func requires(_ engines: String) -> String { String(format: t("store.detail.requires", "Works with cmux %@"), engines) }
    static func screenshot(_ number: Int) -> String { String(format: t("store.detail.screenshot", "Screenshot %@"), String(number)) }
    static func versionLine(_ version: String) -> String { String(format: t("store.updates.version", "Version %@"), version) }

    static var updatesEmpty: String { t("store.updates.empty", "All apps are up to date") }
    static var updatesLoading: String { t("store.updates.loading", "Checking for updates…") }
    static var noMatches: String { t("store.empty.noMatches", "No apps match") }
    static var noneInstalled: String { t("store.empty.noneInstalled", "No apps installed") }
    static var noneInstalledHint: String { t("store.empty.noneInstalledHint", "Choose Discover to find and install apps.") }
    static var loadFailed: String { t("store.error.load", "Could not load the store") }
    static var badgeInstalled: String { t("store.badge.installed", "Installed") }
    static var badgeDisabled: String { t("store.badge.disabled", "Disabled") }
    static var badgeUpdate: String { t("store.badge.updateAvailable", "Update available") }
    static var verified: String { t("store.tier.verified", "Verified") }

    static func risk(_ risk: String) -> String? {
        switch risk {
        case "sensitive": t("store.risk.sensitive", "Sensitive")
        case "restricted": t("store.risk.restricted", "Restricted")
        default: nil
        }
    }

    /// The place a contribution kind shows up in; nil for a kind the store does not name.
    static func place(_ kind: String) -> String? {
        switch kind {
        case "section": t("store.contribution.section", "Sidebar")
        case "sidebarWidget": t("store.contribution.sidebarWidget", "Sidebar widget")
        case "statusItem": t("store.contribution.statusItem", "Title bar")
        case "pane": t("store.contribution.pane", "Its own tab")
        case "newTab": t("store.contribution.newTab", "New Tab")
        case "sessionInfo": t("store.contribution.sessionInfo", "Session Info")
        case "command": t("store.contribution.command", "Command palette")
        default: nil
        }
    }

    /// A category's label; the id itself for a category the table does not name.
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

    /// A permission group's heading, from its scope's namespace; nil for one the table does not know.
    static func scopeHeading(_ scope: String) -> String? {
        let namespace = scope.split(separator: ":", maxSplits: 1).first.map(String.init) ?? scope
        return switch namespace {
        case "cloud": t("store.scope.cloud", "Cloud machines")
        case "coderouter": t("store.scope.coderouter", "CodeRouter")
        case "fs": t("store.scope.files", "Files")
        case "terminal": t("store.scope.terminal", "Terminals")
        case "actions": t("store.scope.actions", "Actions in cmux")
        case "net": t("store.scope.network", "Internet")
        case "op": t("store.scope.cmux", "Through cmux")
        case "workspace": t("store.scope.workspaces", "Workspaces")
        case "notifications": t("store.scope.notifications", "Notifications")
        case "integration": t("store.scope.accounts", "Connected accounts")
        case "clipboard": t("store.scope.clipboard", "Clipboard")
        case "storage": t("store.scope.storage", "Saved data")
        case "sidebar": t("store.scope.sidebar", "Sidebar")
        case "process": t("store.scope.programs", "Helper programs")
        default: nil
        }
    }

    /// A deploy target's words; the target itself for a kind the table does not name.
    static func deployTarget(_ target: String) -> String {
        switch target {
        case "self-hosted": t("store.deploy.target.selfHosted", "A machine you host (SSH with Docker or Podman)")
        case "cloud-vm": t("store.deploy.target.cloudVM", "Your cmux Cloud machine")
        case "team-vm": t("store.deploy.target.teamVM", "Your team’s cmux Cloud machine")
        case "local": t("store.deploy.target.local", "This Mac")
        default: target
        }
    }

    /// A section's title: the owner's string key when this table has it, else the words its kind has.
    static func sectionTitle(_ section: AppStoreSection) -> String {
        if !section.titleKey.isEmpty {
            let resolved = Bundle.module.localizedString(forKey: section.titleKey, value: nil, table: nil)
            if resolved != section.titleKey { return resolved }
        }
        switch section.kind {
        case .featured: return featured
        case .recent: return newAndUpdated
        case .chart: return topApps
        case .category: return section.category.map { category($0) } ?? allApps
        }
    }
}
