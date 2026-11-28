import Foundation

/// Strings of the App Store window and app surfaces (Resources/Localizable.xcstrings).
nonisolated enum AppsStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .localizedModule)
    }

    static var windowTitle: String { t("store.window.title", "App Store") }
    /// Undo Look Change (`customize.revert`) could not run: no bundled `cmux` CLI.
    static var customizeNoCLI: String { t("customize.revert.noCLI", "This build does not include the cmux CLI.") }
    /// An app mount failed and the supervisor gave no reason.
    static var mountFailed: String { t("apps.mount.failed", "The app could not start") }
    /// A failed app view's error card: runs the app's script again from its saved files.
    // retry-prompt-ok: runs the app's script again, which may act through its grants; a saved edit reloads by itself
    static var reload: String { t("apps.mount.reload", "Reload") }
    static var reloadHelp: String { t("apps.mount.reload.help", "Run the script again from its saved files") }
    /// Why an app's overlay did not open (``AppOverlayPresenter/Refusal``).
    static var overlayGesture: String { t("apps.overlay.gesture", "An app overlay opens only when you open it in cmux") }
    static var overlayUndeclared: String { t("apps.overlay.undeclared", "This app has no overlay") }
    static var overlayNoWindow: String { t("apps.overlay.noWindow", "No window to show the overlay in") }
    /// The palette row that opens an app's overlay (%@: the app's name).
    static func overlayOpen(_ name: String) -> String { String(format: t("apps.overlay.open", "Open %@ Overlay"), name) }
    /// A failed mount's row (AppFailureCopy): its script threw or did not parse.
    static var failureScript: String { t("apps.failure.script", "This section's script has an error") }
    /// Where a script error is (`file` nil for an older host's unnamed `eval_script`), and the
    /// engine's message.
    static func failureScriptAt(file: String?, line: String, column: String, message: String) -> String {
        switch (file, message.isEmpty) {
        case (nil, true): String(format: t("apps.failure.scriptAtOnly", "Line %1$@, column %2$@"), line, column)
        case (nil, false): String(format: t("apps.failure.scriptAt", "Line %1$@, column %2$@: %3$@"), line, column, message)
        case (let file?, true):
            String(format: t("apps.failure.scriptInAtOnly", "%1$@ · Line %2$@, column %3$@"), file, line, column)
        case (let file?, false):
            String(format: t("apps.failure.scriptInAt", "%1$@ · Line %2$@, column %3$@: %4$@"), file, line, column, message)
        }
    }
    /// The scene went past the node or depth budget.
    static var failureTooLarge: String { t("apps.failure.tooLarge", "This section is too large to show") }
    /// Any other failed mount; the reason is under Details.
    static var failureGeneric: String { t("apps.failure.generic", "This section couldn't load") }
    static var failureCopy: String { t("apps.failure.copy", "Copy Error") }
    static var failureCopied: String { t("apps.failure.copied", "Copied") }
    static var failureDetails: String { t("apps.failure.details", "Details") }
    static var failureHideDetails: String { t("apps.failure.hideDetails", "Hide Details") }
    /// The marker under a kept app view whose last save did not load; the file and line follow it.
    static var reloadFailed: String { t("apps.mount.reloadFailed", "Not reloaded") }
    /// The second line of an app's toast detail (`cmux.toast`): the app that showed it.
    static func toastSource(_ app: String) -> String { String(format: t("apps.toast.source", "From %@"), app) }
    /// `app.menu.run` on a row no visible app has now, or with no workspace or tab to act on.
    static var menuUnknownRow: String { t("apps.menu.unknownRow", "No installed app has this menu item.") }
    static var menuNoTarget: String { t("apps.menu.noTarget", "Choose a workspace or tab for this menu item.") }
    static var discover: String { t("store.tab.discover", "Discover") }
    static var installed: String { t("store.tab.installed", "Installed") }
    static var features: String { t("store.tab.features", "Features") }
    static var noFeatureMatches: String { t("store.empty.noFeatureMatches", "No features match") }
    static var get: String { t("store.feature.action.get", "Get") }
    static var featureKeptOn: String { t("store.feature.keptOn", "Your organization recommends this, so it stays on") }

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
    static var noMatches: String { t("store.empty.noMatches", "No apps match") }
    static var noneInstalled: String { t("store.empty.noneInstalled", "No apps installed") }
    static func unknownApp(_ id: String) -> String { String(format: t("apps.client.unknownApp", "No app %@"), id) }

    private static var notConnected: String { t("apps.store.disconnected.notConnected", "This machine isn't connected") }

    /// Why the app supervisor cannot be reached (store banner, app sections).
    static func unavailable(_ reason: AppsUnavailableReason) -> String {
        switch reason {
        case .noAppHost: t("apps.store.disconnected.noAppHost", "Apps can’t run in this build of cmux")
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
    static var crashed: String { t("apps.store.host.crashed", "The app stopped unexpectedly") }

    static var permissions: String { t("store.detail.permissions", "Permissions") }
    static var noPermissions: String { t("store.detail.noPermissions", "No permissions") }
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
