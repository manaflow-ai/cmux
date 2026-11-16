import Foundation

/// The server's own refusals (Resources/Localizable.xcstrings). The server pages' text shares the
/// table (webviews/src/pages/server-cards reads it through gen-strings.mjs).
nonisolated enum ServerStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var startFailed: String { t("refusal.startFailed", "Could not start the server. Run `cmux server up` in a terminal to see why.") }
    static var stopFailed: String { t("refusal.stopFailed", "Could not stop the server. Run `cmux server down` in a terminal to see why.") }
    static var pairStartFailed: String { t("refusal.pairStartFailed", "Could not start pairing. Run `cmux server pair` in a terminal to see why.") }
    static var unreachable: String { t("status.unreachable", "Server is not running") }

    /// The card panel's native Add Server control (ServerPageProvider.personControl); the page's
    /// keys of the same table (approver.*).
    static var approve: String { t("approver.approve", "Approve") }
    static var adding: String { t("approver.adding", "Adding…") }
    static var tryAgain: String { t("approver.retry", "Try Again") }
}
