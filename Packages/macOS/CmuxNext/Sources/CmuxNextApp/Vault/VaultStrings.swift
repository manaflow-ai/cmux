import Foundation

/// Session vault strings (table Vault.xcstrings).
enum VaultStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Vault", bundle: .module)
    }

    static var title: String { t("vault.title", "Vault") }
    static var searchPlaceholder: String { t("vault.searchPlaceholder", "Search sessions…") }
    static var empty: String { t("vault.empty", "No agent sessions yet. Sessions of Claude Code, Codex and other agents run in cmux terminals show here.") }
    static var noMatch: String { t("vault.noMatch", "No session matches the search.") }
    static var refresh: String { t("vault.refresh", "Refresh") }
    static var running: String { t("vault.running", "Running") }
    static var focusSession: String { t("vault.menu.focusSession", "Focus Session") }
    static var openSession: String { t("vault.menu.openSession", "Open Session") }
    static var resumeInNewWorkspace: String { t("vault.menu.resumeInNewWorkspace", "Resume Session in New Workspace") }
    static var copyResumeCommand: String { t("vault.menu.copyResumeCommand", "Copy Resume Command") }
    static var openPullRequest: String { t("vault.menu.openPullRequest", "Open Session Pull Request") }
    static var noSessionSelected: String { t("vault.refusal.noSessionSelected", "Select a session in the Vault first") }
    static var notRunning: String { t("vault.refusal.notRunning", "That session is not running in a tab") }
    static var noPullRequest: String { t("vault.refusal.noPullRequest", "That session has no pull request") }
}
