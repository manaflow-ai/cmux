import Foundation

/// Strings of the guided CSV import (table Passwords).
nonisolated enum PasswordCSVGuideStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Passwords", bundle: .module)
    }

    static var sourceTitle: String { t("passwords.csv.guide.title", "Import Passwords from CSV") }
    static var sourceMessage: String {
        t("passwords.csv.guide.message", "cmux imports a CSV file that the app with your passwords exports. Where are your passwords now?")
    }
    static var sourceLabel: String { t("passwords.csv.guide.source", "Passwords from:") }
    static var continueTitle: String { t("passwords.csv.guide.continue", "Continue") }
    static var cancel: String { t("passwords.csv.guide.cancel", "Cancel") }
    static var openPasswords: String { t("passwords.csv.guide.openPasswords", "Open Passwords") }
    static var chooseFile: String { t("passwords.csv.guide.chooseFile", "Choose File…") }

    /// Product names are not translated; "other" is.
    static func name(_ source: PasswordCSVSource) -> String {
        switch source {
        case .apple: t("passwords.csv.guide.name.apple", "Safari or Apple Passwords")
        case .onePassword: "1Password"
        case .bitwarden: "Bitwarden"
        case .other: t("passwords.csv.guide.name.other", "A CSV file I already have (Chrome, Edge, Firefox, others)")
        }
    }

    static func stepsTitle(_ source: PasswordCSVSource) -> String {
        String(format: t("passwords.csv.guide.stepsTitle", "Export Your Passwords from %@"), name(source))
    }

    static func steps(_ source: PasswordCSVSource) -> [String] {
        switch source {
        case .apple:
            [t("passwords.csv.guide.apple.1", "1. Open the Passwords app (on macOS 14 or earlier, open Safari)."),
             t("passwords.csv.guide.apple.2", "2. Choose File > Export All Passwords to File… (in Safari: File > Export > Passwords…)."),
             t("passwords.csv.guide.apple.3", "3. Save the CSV file, then choose it here.")]
        case .onePassword:
            [t("passwords.csv.guide.1password.1", "1. In 1Password, choose File > Export, then choose your account."),
             t("passwords.csv.guide.1password.2", "2. Enter your account password, choose the CSV format, then click Export Data."),
             t("passwords.csv.guide.1password.3", "3. Choose the saved CSV file here. cmux imports only website sign-ins.")]
        case .bitwarden:
            [t("passwords.csv.guide.bitwarden.1", "1. In Bitwarden, choose File > Export Vault (in the web vault: Tools > Export Vault)."),
             t("passwords.csv.guide.bitwarden.2", "2. Choose the .csv file format, confirm with your master password, then save."),
             t("passwords.csv.guide.bitwarden.3", "3. Choose the saved CSV file here.")]
        case .other: []
        }
    }
}
