import Foundation

/// Strings of the titlebar history menu and the history read status (Resources/Localizable.xcstrings;
/// the History page's own are webviews/src/pages/history/Localizable.xcstrings).
nonisolated enum HistoryStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var menuShowAll: String { t("titlebarHistory.showFull", "Show Full History") }
    static var menuRecentlyClosed: String { t("titlebarHistory.recentlyClosed", "Recently Closed") }
    static var menuNothingClosed: String { t("titlebarHistory.nothingClosed", "Nothing closed yet") }
    static var menuClosedUnavailable: String { t("titlebarHistory.closedUnavailable", "Closed items appear once cmux connects") }
    static var readFailed: String { t("status.readFailed", "History didn't load") }
    static var readFailedHint: String { t("status.readFailedHint", "cmux did not answer in time. Press Return to try again.") }
    static var tryAgain: String { t("status.tryAgain", "Try Again") }
    static var stillLoading: String { t("status.stillLoading", "Still loading history…") }
    static var stillLoadingHint: String { t("status.stillLoadingHint", "This list is not complete yet. It updates by itself.") }
    static func menuHeader(_ kind: LocationTrailMenuSection.Kind) -> String? {
        switch kind {
        case .scope: nil
        case .otherWorkspaces: t("titlebarHistory.otherWorkspaces", "Other Workspaces")
        case .browser: t("titlebarHistory.browser", "Browser")
        case .chatsAndPages: t("titlebarHistory.chatsAndPages", "Chats and Pages")
        case .terminals: t("titlebarHistory.terminals", "Terminals")
        }
    }
}
