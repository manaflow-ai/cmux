import CmuxSettings
import Foundation

@MainActor
extension AppSection {
    func languageDisplayName(_ language: AppLanguage) -> String {
        // Mirrors legacy AppLanguage.displayName: native name plus an
        // English suffix in parentheses, except for English and
        // Portuguese (Brasil) which already carry the locale name.
        switch language {
        case .system: return String(localized: "language.system", defaultValue: "System")
        case .en: return "English"
        case .ar: return "\u{200E}العربية (Arabic)"
        case .bs: return "Bosanski (Bosnian)"
        case .zhHans: return "简体中文 (Chinese Simplified)"
        case .zhHant: return "繁體中文 (Chinese Traditional)"
        case .da: return "Dansk (Danish)"
        case .de: return "Deutsch (German)"
        case .es: return "Español (Spanish)"
        case .fr: return "Français (French)"
        case .it: return "Italiano (Italian)"
        case .ja: return "日本語 (Japanese)"
        case .ko: return "한국어 (Korean)"
        case .nb: return "Norsk (Norwegian)"
        case .pl: return "Polski (Polish)"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский (Russian)"
        case .th: return "ไทย (Thai)"
        case .tr: return "Türkçe (Turkish)"
        case .vi: return "Tiếng Việt (Vietnamese)"
        }
    }

    func whatsNewSubtitle(_ mode: WhatsNewPresentationMode) -> String {
        switch mode {
        case .off:
            return String(localized: "settings.app.whatsNew.subtitleOff", defaultValue: "Nothing after updates. Help > What's New in cmux still opens the recap.")
        case .quiet:
            return String(localized: "settings.app.whatsNew.subtitleQuiet", defaultValue: "A dot on the sidebar help button marks new highlights. Nothing opens on its own.")
        case .sheet:
            return String(localized: "settings.app.whatsNew.subtitleSheet", defaultValue: "Open the recap once after the first launch of a new version.")
        }
    }

    func warnCloseXSubtitle(hideCloseButton: Bool) -> String {
        // The hidden-button status replaces the description. The warning
        // cannot apply while close buttons are hidden.
        if hideCloseButton {
            return String(
                localized: "settings.app.warnBeforeClosingTabXButton.subtitleHidden",
                defaultValue: "Unavailable while tab close buttons are hidden."
            )
        }
        return String(
            localized: "settings.app.warnBeforeClosingTabXButton.subtitle",
            defaultValue: "Clicking a tab's close button asks for confirmation first."
        )
    }
}
