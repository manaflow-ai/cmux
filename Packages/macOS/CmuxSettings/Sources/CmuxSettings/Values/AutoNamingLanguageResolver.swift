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
        return language(fromIdentifier: raw) ?? Self.fallback
    }

    private func resolveSystemLanguage() -> AutoNamingResolvedLanguage {
        for identifier in preferredLanguages + [currentLocaleIdentifier] {
            if let language = language(fromIdentifier: identifier) {
                return language
            }
        }
        return Self.fallback
    }

    private func language(fromIdentifier raw: String) -> AutoNamingResolvedLanguage? {
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

    private func normalizedBCP47Tag(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.allSatisfy({ byte in
            isASCIIAlphanumeric(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        }) else {
            return nil
        }
        let pieces = trimmed
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard pieces.allSatisfy({ !$0.isEmpty }),
              let language = pieces.first?.lowercased(),
              Self.isASCIILetterSubtag(language, length: 2...3) else {
            return nil
        }
        var normalized = [language]
        var index = pieces.index(after: pieces.startIndex)
        if index < pieces.endIndex,
           isASCIILetterSubtag(pieces[index], length: 4...4) {
            normalized.append(titlecasedScriptSubtag(pieces[index]))
            index = pieces.index(after: index)
        }
        if index < pieces.endIndex,
           isASCIIRegionSubtag(pieces[index]) {
            normalized.append(pieces[index].uppercased())
            index = pieces.index(after: index)
        }
        while index < pieces.endIndex {
            let piece = pieces[index]
            let lowercased = piece.lowercased()
            if isASCIIAlphanumericSubtag(piece, length: 4...8) {
                normalized.append(lowercased)
                index = pieces.index(after: index)
                continue
            }
            guard isASCIIAlphanumericSubtag(piece, length: 1...1) else {
                return nil
            }
            normalized.append(lowercased)
            index = pieces.index(after: index)
            let subtagLength = lowercased == "x" ? 1...8 : 2...8
            let subtagStart = index
            while index < pieces.endIndex,
                  isASCIIAlphanumericSubtag(pieces[index], length: subtagLength) {
                normalized.append(pieces[index].lowercased())
                index = pieces.index(after: index)
            }
            guard index > subtagStart else { return nil }
        }
        return normalized.joined(separator: "-")
    }

    private func isASCIILetterSubtag(_ value: String, length: ClosedRange<Int>) -> Bool {
        let bytes = Array(value.utf8)
        return length.contains(bytes.count) && bytes.allSatisfy(isASCIILetter)
    }

    private func isASCIIRegionSubtag(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        if bytes.count == 2 {
            return bytes.allSatisfy(isASCIILetter)
        }
        return bytes.count == 3 && bytes.allSatisfy(isASCIIDigit)
    }

    private func isASCIIAlphanumericSubtag(_ value: String, length: ClosedRange<Int>) -> Bool {
        let bytes = Array(value.utf8)
        return length.contains(bytes.count) && bytes.allSatisfy(isASCIIAlphanumeric)
    }

    private func titlecasedScriptSubtag(_ value: String) -> String {
        let lowercased = value.lowercased()
        return lowercased.prefix(1).uppercased() + String(lowercased.dropFirst())
    }

    private func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || isASCIIDigit(byte)
    }

    private func isASCIILetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private func isASCIIDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
