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

    func interfaceDensitySubtitle(_ density: InterfaceDensity) -> String {
        switch density {
        case .comfortable:
            return String(
                localized: "settings.app.density.comfortable.subtitle",
                defaultValue: "Larger icons and click targets in the titlebar and sidebar footer."
            )
        case .standard:
            return String(
                localized: "settings.app.density.standard.subtitle",
                defaultValue: "The original icon and click target sizes."
            )
        case .compact:
            return String(
                localized: "settings.app.density.compact.subtitle",
                defaultValue: "Smaller icons. Titlebar, pane tab bar, and sidebar footer buttons fade until you point at them. Notification and update badges stay visible."
            )
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
