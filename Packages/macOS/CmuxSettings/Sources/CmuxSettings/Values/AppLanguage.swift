import Foundation

/// User-selected language for the cmux UI. Raw values match the
/// `AppleLanguages` BCP-47 identifiers cmux uses on disk.
public enum AppLanguage: String, CaseIterable, Sendable, SettingCodable {
    case system, en, ar, bs, zhHans = "zh-Hans", zhHant = "zh-Hant", da, de, es, fr, it, ja, ko, nb, pl, ptBR = "pt-BR", ru, th, tr, vi

    /// Resolves an explicit VS Code display locale, including system-language users.
    /// The language pack must still be installed in VS Code; unavailable locales
    /// use English, matching VS Code's documented fallback.
    public func resolvedVSCodeLocale(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let identifier = (self == .system ? preferredLanguages.first ?? "en" : rawValue)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let components = identifier.split(separator: "-").map(String.init)
        guard let language = components.first else { return "en" }
        switch language {
        case "zh":
            if components.contains("hant") || components.contains("tw") || components.contains("hk") || components.contains("mo") {
                return "zh-tw"
            }
            return "zh-cn"
        case "pt": return "pt-br"
        case "en", "de", "es", "fr", "it", "ja", "ko", "ru", "tr", "pl", "cs", "hu": return language
        default: return "en"
        }
    }
}
