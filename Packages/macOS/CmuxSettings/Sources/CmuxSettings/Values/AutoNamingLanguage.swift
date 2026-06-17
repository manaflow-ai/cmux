import Foundation

/// Output-language policy for workspace/tab auto-naming.
///
/// The stored `automation.autoNamingLanguage` setting is an open string so the
/// JSON config accepts any BCP-47 tag, with two reserved sentinels:
/// ``autoValue`` ("auto", the default — follow the conversation) and
/// ``systemValue`` ("system" — derive from the OS preferred languages). Lives
/// in `CmuxSettings` (imported by both the app and the bundled `cmux` CLI) so
/// the Settings picker and the probe that feeds the summarizer share one
/// resolution path.
/// lint:allow namespace-type — stateless, dependency-free language policy shared by the Settings picker and the auto-naming probe.
public enum AutoNamingLanguage {
    /// Default: emit the title in the conversation's own language.
    public static let autoValue = "auto"
    /// Derive the title language from the macOS preferred languages.
    public static let systemValue = "system"

    /// Common languages surfaced in the Settings picker, in display order. The
    /// JSON config accepts any BCP-47 tag; this list only seeds the menu.
    public static let commonTags: [String] = [
        "en", "ja", "zh-Hans", "zh-Hant", "ko",
        "es", "fr", "de", "pt-BR", "it", "ru", "hi", "ar",
    ]

    /// Resolves the stored setting into the concrete BCP-47 tag the summarizer
    /// should target, or `nil` to follow the conversation (the "auto"
    /// behavior). Pure and dependency-injected so it is unit testable without
    /// the app: the caller passes the live preferred-languages list (the app
    /// supplies `Locale.preferredLanguages`). `system` with no usable preferred
    /// language, an empty value, or "auto" all collapse to `nil`, so a bad
    /// value never breaks naming.
    public static func resolvedLanguageTag(
        setting: String?,
        preferredLanguages: [String]
    ) -> String? {
        let value = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.caseInsensitiveCompare(autoValue) == .orderedSame {
            return nil
        }
        if value.caseInsensitiveCompare(systemValue) == .orderedSame {
            for candidate in preferredLanguages {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return nil
        }
        return value
    }
}
