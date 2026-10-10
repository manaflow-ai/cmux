import Foundation

/// Strings of the history page (Resources/Localizable.xcstrings).
nonisolated enum HistoryStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var title: String { t("page.title", "History") }
    static var searchPlaceholder: String { t("page.search", "Search history") }
    static var empty: String { t("page.empty", "No history") }
    static var emptySearch: String { t("page.emptySearch", "No matches") }
    static var clear: String { t("page.clear", "Clear History…") }
    static var groupBy: String { t("page.groupBy", "Group By") }
    static var cookieBackups: String { t("page.cookieBackups", "Cookie Backups…") }
    static var cookieBackupsTitle: String { t("cookieBackups.title", "Cookie Backups") }
    static var cookieBackupsExplanation: String {
        t("cookieBackups.explanation", "When an agent clears cookies in a browser tab, cmux keeps an encrypted copy on this Mac so the agent can undo the clear. Only you can delete these copies.")
    }
    static var cookieBackupsEmpty: String { t("cookieBackups.empty", "No cookie backups") }
    static var cookieBackupsDelete: String { t("cookieBackups.delete", "Delete") }
    static var cookieBackupsDeleteAll: String { t("cookieBackups.deleteAll", "Delete All…") }
    static var cookieBackupsDone: String { t("cookieBackups.done", "Done") }
    static var cookieBackupsConfirmTitle: String { t("cookieBackups.confirm.title", "Delete these cookie backups?") }
    static var cookieBackupsConfirmMessage: String {
        t("cookieBackups.confirm.message", "An agent can no longer undo these cookie clears. You cannot undo this.")
    }
    static var cookieBackupsConfirmDelete: String { t("cookieBackups.confirm.delete", "Delete Backups") }

    static func filter(_ filter: HistoryPageModel.Filter) -> String {
        switch filter {
        case .all: t("filter.all", "All")
        case .pages: t("filter.pages", "Pages")
        case .locations: t("filter.locations", "Locations")
        case .commands: t("filter.commands", "Commands")
        case .agents: t("filter.agents", "Agents")
        case .closed: t("filter.closed", "Closed")
        }
    }

    static func grouping(_ grouping: HistoryGrouping) -> String {
        switch grouping {
        case .day: t("group.day", "Day")
        case .workspace: t("group.workspace", "Workspace")
        case .machine: t("group.machine", "Machine")
        }
    }

    static func range(_ range: HistoryRange) -> String {
        switch range {
        case .hour: t("range.hour", "Last Hour")
        case .today: t("range.today", "Today")
        case .week: t("range.week", "Last 7 Days")
        case .month: t("range.month", "Last 4 Weeks")
        case .all: t("range.all", "All Time")
        }
    }

    static var thisMac: String { t("group.thisMac", "This Mac") }
    static var noWorkspace: String { t("group.noWorkspace", "No Workspace") }
    static var open: String { t("menu.open", "Open") }
    static var openInNewTab: String { t("menu.openInNewTab", "Open in New Tab") }
    static var reopen: String { t("menu.reopen", "Reopen") }
    static var resume: String { t("menu.resume", "Resume Agent Session") }
    static var goTo: String { t("menu.goTo", "Go To") }
    static var copyURL: String { t("menu.copyURL", "Copy URL") }
    static var copySessionID: String { t("menu.copySessionID", "Copy Session ID") }
    static var copyCommand: String { t("menu.copyCommand", "Copy Command") }
    static var runAgain: String { t("menu.runAgain", "Run Again") }
    static var remove: String { t("menu.remove", "Remove from History") }
    static var removeSite: String { t("menu.removeSite", "Remove All from This Site") }
    static var current: String { t("row.current", "Current") }
    static var offline: String { t("row.offline", "Offline") }
    static var running: String { t("row.running", "Running") }
}
