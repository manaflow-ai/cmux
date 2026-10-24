import Foundation

/// The Firefox primary password prompt's text (`Passwords.xcstrings` in this module).
enum FirefoxPrimaryPasswordStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Passwords", bundle: .module)
    }

    static func title(_ browser: String) -> String {
        String(format: t("passwords.firefox.primary.title", "Enter the Primary Password for %@"), browser)
    }

    static var message: String {
        t("passwords.firefox.primary.message",
          "This profile protects its saved passwords with a primary password. cmux uses it once to read them and does not keep it.")
    }

    static var field: String { t("passwords.firefox.primary.field", "Primary password") }
    static var importButton: String { t("passwords.firefox.primary.import", "Import Passwords") }
    static var skip: String { t("passwords.firefox.primary.skip", "Skip Passwords") }
}
