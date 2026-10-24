public import Foundation

extension Bundle {
    /// The sentence for `key` with `arguments` written into it, all in the one language of this bundle that
    /// `preferredLocalizations` picks.
    ///
    /// This is the one path for a localized sentence that holds a number: counts pick the catalog's plural
    /// variation (the looked-up format keeps the string table's plural rules, and `String(format:locale:)`
    /// applies them), and durations and byte counts are written by Foundation in the sentence's language (see
    /// ``LocalizedArgument``). Units take the sentence's language and keep the user's region and numbering
    /// system from `locale`, so an Arabic sentence never holds an English unit and a person who chose Latin
    /// digits keeps them. A language this bundle has no strings for gets the English sentence with English
    /// units.
    ///
    /// The looked-up format must take exactly `arguments`: a `%lld` (or `%ld`) for each ``LocalizedArgument/count(_:)``,
    /// a `%@` for each other argument, each used once. A translation that does not (a copy edit that added a
    /// `%@`, turned one into `%lld`, or wrote a 32-bit `%d` for a count) is not passed to `String(format:)`, where it would read past the
    /// arguments; `value` is used instead. scripts/localization_defaults.py compares `value` with the catalog's
    /// English.
    ///
    /// ```swift
    /// Bundle.module.localizedString(
    ///     forKey: "home.chief.noReply",
    ///     value: "No reply from the Chief for %@. It retries on its own and tells you if it cannot answer.",
    ///     table: "Home", arguments: [.duration(.seconds(minutes * 60), units: [.minutes])],
    ///     preferredLocalizations: Bundle.module.preferredLocalizations)
    /// ```
    ///
    /// - Parameters:
    ///   - key: The catalog key of the sentence.
    ///   - value: The English sentence, used when the table has no entry for `key` or its entry does not take
    ///     `arguments`.
    ///   - table: The string table, nil for `Localizable`.
    ///   - arguments: The values to write into the sentence, in argument order.
    ///   - preferredLocalizations: The languages to choose from, most preferred first; pass this bundle's
    ///     `preferredLocalizations` for the user's choice, or a fixed list in tests.
    ///   - locale: The locale whose region and numbering system the numbers use (the user's by default); its
    ///     language is replaced by the picked one.
    /// - Returns: The sentence in the picked language.
    public func localizedString(forKey key: String, value: String, table: String?, arguments: [LocalizedArgument],
                                preferredLocalizations: [String], locale: Locale = .current) -> String {
        let language = localizationLanguage(preferredLocalizations)
        let sentenceLocale = Self.locale(locale, language: language)
        let looked = localizedString(forKey: key, value: value, table: table, preferredLocalizations: [language])
        let format = formatTakes(looked, arguments) ? looked : value
        return String(format: format, locale: sentenceLocale, arguments: arguments.map { $0.formatArgument(in: sentenceLocale) })
    }

    /// `duration` alone, in CLDR's abbreviated units of the language of this bundle that `preferredLocalizations`
    /// picks ("12 ms", ar "12 ملي ث"), with the region and numbering system of `locale`.
    ///
    /// Use it where a duration is the whole text (a metric next to a label), so no catalog entry carries a unit.
    ///
    /// - Parameters:
    ///   - duration: The duration to write.
    ///   - units: The units it may be written in (`[.milliseconds]` writes whole milliseconds).
    ///   - preferredLocalizations: The languages to choose from, most preferred first.
    ///   - locale: The locale whose region and numbering system the number uses (the user's by default).
    /// - Returns: The written duration.
    public func localizedDuration(_ duration: Duration, units: Set<Duration.UnitsFormatStyle.Unit>,
                                  preferredLocalizations: [String], locale: Locale = .current) -> String {
        let sentenceLocale = Self.locale(locale, language: localizationLanguage(preferredLocalizations))
        return duration.formatted(.units(allowed: units, width: .abbreviated).locale(sentenceLocale))
    }

    /// The localization of this bundle that `preferences` picks; the development localization when none matches.
    private func localizationLanguage(_ preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: localizations, forPreferences: preferences).first ?? developmentLocalization ?? "en"
    }

    /// `base` with its language replaced by `language`: the region, numbering system and other preferences stay.
    private static func locale(_ base: Locale, language: String) -> Locale {
        var components = Locale.Components(locale: base)
        components.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: components)
    }
}

/// The scalars of a positional argument number (`%2$@`).
private let decimalDigits: ClosedRange<Unicode.Scalar> = "0"..."9"

/// Whether `format` takes exactly `arguments`: a 64-bit integer specifier (`%ld`, `%lld`) for each count, a `%@`
/// for each other argument, each argument once, and no other conversion. A plural rule token (`%#@name@`, the
/// form a string table's plural variation is looked up as) passes: its variations are checked against English by
/// scripts/cmux-next/check-l10n.sh.
private func formatTakes(_ format: String, _ arguments: [LocalizedArgument]) -> Bool {
    let characters = Array(format.unicodeScalars)
    var used: [Int: Bool] = [:]  // argument number (1-based) -> is an integer specifier
    var next = 1
    var index = 0
    while index < characters.count {
        guard characters[index] == "%" else { index += 1; continue }
        index += 1
        guard index < characters.count else { return false }
        if characters[index] == "%" { index += 1; continue }
        var digits = ""
        var probe = index
        while probe < characters.count, decimalDigits.contains(characters[probe]) {
            digits.unicodeScalars.append(characters[probe])
            probe += 1
        }
        let position: Int
        if !digits.isEmpty, probe < characters.count, characters[probe] == "$", let explicit = Int(digits) {
            position = explicit
            index = probe + 1
        } else {
            position = next
            next += 1
        }
        if index + 1 < characters.count, characters[index] == "#", characters[index + 1] == "@" { return true }
        var length = ""
        while index < characters.count, characters[index] == "l", length.count < 2 {
            length.append("l")
            index += 1
        }
        guard index < characters.count else { return false }
        let isCount: Bool
        switch characters[index] {
        case "d" where !length.isEmpty: isCount = true
        case "@" where length.isEmpty: isCount = false
        default: return false
        }
        index += 1
        guard position >= 1, used[position] == nil else { return false }
        used[position] = isCount
    }
    guard used.count == arguments.count else { return false }
    for (offset, argument) in arguments.enumerated() where used[offset + 1] != argument.isCount {
        return false
    }
    return true
}
