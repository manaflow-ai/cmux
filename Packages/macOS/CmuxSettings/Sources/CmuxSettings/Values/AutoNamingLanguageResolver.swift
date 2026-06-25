import Foundation

/// Resolves the language used by workspace/tab auto-naming prompts.
public struct AutoNamingLanguageResolver: Sendable {
    /// Fallback used when neither the setting nor system locale can be resolved.
    public static let fallback = AutoNamingResolvedLanguage(promptName: "English", bcp47Tag: "en")

    private let catalog: AutoNamingLanguageCatalog
    private let preferredLanguages: [String]
    private let currentLocaleIdentifier: String

    /// Creates a resolver.
    /// - Parameters:
    ///   - catalog: Catalog of explicit choices.
    ///   - preferredLanguages: Ordered system language identifiers.
    ///   - currentLocaleIdentifier: Current locale identifier fallback.
    public init(
        catalog: AutoNamingLanguageCatalog = AutoNamingLanguageCatalog(),
        preferredLanguages: [String] = NSLocale.preferredLanguages,
        currentLocaleIdentifier: String = Locale.current.identifier
    ) {
        self.catalog = catalog
        self.preferredLanguages = preferredLanguages
        self.currentLocaleIdentifier = currentLocaleIdentifier
    }

    /// Resolves a raw setting value into a prompt language.
    /// - Parameter rawSetting: `"auto"` follows the system language; explicit
    ///   slugs and BCP-47 tags resolve directly.
    /// - Returns: The effective prompt language.
    public func resolve(rawSetting: String?) -> AutoNamingResolvedLanguage {
        let raw = rawSetting?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw.lowercased() == AutoNamingLanguageCatalog.autoSlug {
            return resolveSystemLanguage()
        }
        if let option = catalog.option(forSlug: raw) {
            return AutoNamingResolvedLanguage(promptName: option.promptName, bcp47Tag: option.bcp47Tag)
        }
        return Self.language(fromIdentifier: raw) ?? Self.fallback
    }

    private func resolveSystemLanguage() -> AutoNamingResolvedLanguage {
        for identifier in preferredLanguages + [currentLocaleIdentifier] {
            if let language = Self.language(fromIdentifier: identifier) {
                return language
            }
        }
        return Self.fallback
    }

    private static func language(fromIdentifier raw: String) -> AutoNamingResolvedLanguage? {
        guard let tag = normalizedBCP47Tag(raw) else { return nil }
        let languageCode = tag.split(separator: "-", maxSplits: 1).first.map(String.init) ?? tag
        let englishLocale = Locale(identifier: "en")
        let promptName = englishLocale.localizedString(forIdentifier: tag)
            ?? englishLocale.localizedString(forLanguageCode: languageCode)
        guard let promptName = promptName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !promptName.isEmpty,
              promptName.caseInsensitiveCompare(tag) != .orderedSame else {
            return nil
        }
        return AutoNamingResolvedLanguage(promptName: promptName, bcp47Tag: tag)
    }

    private static func normalizedBCP47Tag(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pieces = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
        guard let language = pieces.first?.lowercased(),
              language.count >= 2,
              language.allSatisfy({ $0.isLetter }) else {
            return nil
        }
        let normalizedRest = pieces.dropFirst().map { piece -> String in
            if piece.count == 2, piece.allSatisfy({ $0.isLetter }) {
                return piece.uppercased()
            }
            if piece.count == 4, piece.allSatisfy({ $0.isLetter }) {
                return piece.prefix(1).uppercased() + piece.dropFirst().lowercased()
            }
            return piece
        }
        return ([language] + normalizedRest).joined(separator: "-")
    }
}
