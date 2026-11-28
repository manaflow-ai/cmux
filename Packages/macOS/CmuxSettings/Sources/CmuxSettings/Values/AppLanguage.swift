import Foundation

/// User-selected language for the cmux UI. Raw values match the
/// `AppleLanguages` BCP-47 identifiers cmux uses on disk.
public enum AppLanguage: String, CaseIterable, Sendable, SettingCodable {
    case system, en, ar, bs, zhHans = "zh-Hans", zhHant = "zh-Hant", da, de, es, fr, it, ja, ko, nb, pl, ptBR = "pt-BR", ru, th, tr, vi
}
