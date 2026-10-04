import Foundation

/// Strings of the page host (Localizable.xcstrings): the native confirmation sheet.
nonisolated enum PageStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var installTitle: String { t("pages.confirm.installTitle", "Install “%@”?") }
    static var uninstallTitle: String { t("pages.confirm.uninstallTitle", "Remove “%@”?") }
    static var updateTitle: String { t("pages.confirm.updateTitle", "Update “%@”?") }
    static var grantTitle: String { t("pages.confirm.grantTitle", "Allow “%1$@” to use %2$@?") }
    static var deleteTitle: String { t("pages.confirm.deleteTitle", "Delete “%@”?") }
    static var install: String { t("pages.confirm.install", "Install") }
    static var remove: String { t("pages.confirm.remove", "Remove") }
    static var update: String { t("pages.confirm.update", "Update") }
    static var allow: String { t("pages.confirm.allow", "Allow") }
    static var delete: String { t("pages.confirm.delete", "Delete") }
    static var continueTitle: String { t("pages.confirm.continue", "Continue") }
    static var cancel: String { t("pages.confirm.cancel", "Cancel") }
    static var asksFor: String { t("pages.confirm.asksFor", "It asks for:") }
    static var opensWeb: String { t("pages.confirm.opensWeb", "It opens these web addresses:") }

    static func risk(_ risk: String) -> String {
        switch risk {
        case "restricted": t("pages.risk.restricted", "Restricted")
        case "sensitive": t("pages.risk.sensitive", "Sensitive")
        default: t("pages.risk.standard", "Standard")
        }
    }
}
