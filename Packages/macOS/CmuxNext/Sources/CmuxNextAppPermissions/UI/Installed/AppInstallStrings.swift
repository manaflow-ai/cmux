import Foundation

/// Strings of the app management surfaces (Resources/Localizable.xcstrings).
nonisolated enum AppInstallStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var hide: String { t("install.hide", "Hide") }
    static var unhide: String { t("install.unhide", "Unhide") }
    static var disable: String { t("install.disable", "Disable") }
    static var enable: String { t("install.enable", "Enable") }
    static var remove: String { t("install.remove", "Remove") }
    static var removeEllipsis: String { t("install.removeEllipsis", "Remove…") }
    static var removeCompletely: String { t("install.removeCompletely", "Remove Completely") }
    static var hideInstead: String { t("install.hideInstead", "Hide Instead") }
    static var removeConfirm: String { t("install.removeConfirm", "Removing deletes its data and permissions. Hiding keeps it ready.") }
    static var adminOnly: String { t("install.adminOnly", "Only a team admin can remove it.") }

    static var hiddenChip: String { t("install.state.hidden", "Hidden") }
    static var disabledChip: String { t("install.state.disabled", "Disabled") }
    static var teamChip: String { t("install.state.team", "Team") }

    static var showHidden: String { t("install.showHidden", "Show Hidden Apps") }
    static func showHiddenCount(_ count: Int) -> String { String(format: t("install.showHidden.count", "Show Hidden Apps (%lld)"), count) }
    static var hiddenTitle: String { t("install.hidden.title", "Hidden Apps") }
    static var hiddenNone: String { t("install.hidden.none", "No hidden apps") }
    static var hiddenDetail: String { t("install.hidden.detail", "Hidden apps show nowhere. They still run where you allow it.") }
    static var runsNowhere: String { t("install.hidden.runsNowhere", "Does not run while hidden") }
    static var done: String { t("install.done", "Done") }

    static var whileHidden: String { t("access.title", "While Hidden") }
    static var whileHiddenDetail: String { t("access.detail", "Channels that may still run it while it is hidden.") }
    static var cli: String { t("access.cli", "CLI") }
    static var mcp: String { t("access.mcp", "MCP") }
    static var automations: String { t("access.automations", "Automations") }

    static func reject(_ reject: AppStateReject) -> String {
        switch reject {
        case .adminOnly: adminOnly
        case .notInstalled: t("install.reject.notInstalled", "The app is not installed.")
        case .originNotAllowed, .sourceNotAllowed, .keyReused, .reservedKey: t("install.reject.other", "The change was refused.")
        }
    }
}
