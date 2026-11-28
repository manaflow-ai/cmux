import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// Asks the person for a Firefox profile's primary password during a
/// browser import (`PasswordImporter.PrimaryPasswordPrompt`). The dialog runs
/// on a private dialog center, so the DEBUG `debug.dialog` verb (which reads
/// and sets fields of `CmuxDialogCenter.shared`) can neither see nor fill it:
/// only a person answers. The secure field's text is copied into
/// `SecretBytes` at once and the answer is dropped; cmux never keeps it.
@MainActor
struct FirefoxPrimaryPassword {
    static let field = "primaryPassword"

    static func prompt(_ profile: BrowserSourceProfile) async -> SecretBytes? {
        let center = CmuxDialogCenter()
        let spec = CmuxDialogSpec(
            title: FirefoxPrimaryPasswordStrings.title(profile.browser.displayName),
            lines: [FirefoxPrimaryPasswordStrings.message],
            fields: [.text(id: field, label: FirefoxPrimaryPasswordStrings.field, initial: "", placeholder: nil, secure: true)],
            buttons: [.cancel(FirefoxPrimaryPasswordStrings.skip), CmuxDialogButton(id: "import", title: FirefoxPrimaryPasswordStrings.importButton, role: .default)],
            identifier: "cmux.dialog.firefoxPrimaryPassword")
        let scope: CmuxDialogScope = (NSApp.keyWindow ?? NSApp.mainWindow).map { .window($0) } ?? .app
        let answer = await center.present(spec, in: scope)
        guard answer.button == "import", let text = answer.values[field]?.text, !text.isEmpty else { return nil }
        return SecretBytes(copying: Array(text.utf8))
    }
}

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
