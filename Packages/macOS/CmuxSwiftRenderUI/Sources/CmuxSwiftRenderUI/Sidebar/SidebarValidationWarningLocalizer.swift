import Foundation

/// Resolves package-owned validation warnings for one explicit locale.
struct SidebarValidationWarningLocalizer {
    private let locale: Locale
    private let bundle: Bundle
    private let packagedStrings: [String: [String: String]]

    /// Creates a localizer bound to one locale and package-resource bundle.
    init(locale: Locale, bundle: Bundle = .module) {
        self.locale = locale
        self.bundle = bundle
        self.packagedStrings =
            SidebarValidationWarningCatalog(
                bundle: bundle
            ).strings
    }

    /// Warning emitted when a sidebar produces no visible content.
    var emptyRender: String {
        resolve(
            key: "sidebar.custom.validation.emptyRender",
            fallback: String(
                localized: LocalizedStringResource(
                    "sidebar.custom.validation.emptyRender",
                    defaultValue: "Sidebar rendered no visible content.",
                    locale: locale,
                    bundle: bundle
                )
            )
        )
    }

    /// Warning emitted when removing optional data empties the output.
    var emptyRenderWithoutOptionalData: String {
        resolve(
            key: "sidebar.custom.validation.emptyRenderWithoutOptionalData",
            fallback: String(
                localized: LocalizedStringResource(
                    "sidebar.custom.validation.emptyRenderWithoutOptionalData",
                    defaultValue:
                        "Sidebar rendered no visible content when optional workspace data was absent.",
                    locale: locale,
                    bundle: bundle
                )
            )
        )
    }

    /// Warning emitted when referenced optional data has no rendered effect.
    var missingOptionalDataCoverage: String {
        resolve(
            key: "sidebar.custom.validation.noOptionalDataCoverage",
            fallback: String(
                localized: LocalizedStringResource(
                    "sidebar.custom.validation.noOptionalDataCoverage",
                    defaultValue:
                        "Sidebar output did not change when its referenced optional workspace data was removed.",
                    locale: locale,
                    bundle: bundle
                )
            )
        )
    }

    /// Resolves a key through compiled, packaged, then English fallback text.
    private func resolve(key: String, fallback: String) -> String {
        resolvedCompiledString(forKey: key)
            ?? resolvedPackagedString(forKey: key)
            ?? fallback
    }

    /// Reads a compiled language table without accepting Bundle's unrelated
    /// fallback language when the requested locale is unavailable.
    private func resolvedCompiledString(forKey key: String) -> String? {
        let matchingLocalizations = matchingRequestedLanguage(
            in: bundle.localizations.filter { $0 != "Base" }
        )
        guard !matchingLocalizations.isEmpty else { return nil }
        let preferredLocalizations = Bundle.preferredLocalizations(
            from: matchingLocalizations,
            forPreferences: [locale.identifier]
        )
        for localization in preferredLocalizations {
            guard
                let path = bundle.path(
                    forResource: localization,
                    ofType: "lproj"
                ),
                let languageBundle = Bundle(path: path)
            else {
                continue
            }
            let localized = languageBundle.localizedString(
                forKey: key,
                value: nil,
                table: nil
            )
            if localized != key {
                return localized
            }
        }
        return nil
    }

    /// SwiftPM command-line builds can copy `.xcstrings` without compiling
    /// language tables, so this reads the same packaged catalog as a fallback.
    private func resolvedPackagedString(forKey key: String) -> String? {
        guard let localizations = packagedStrings[key] else { return nil }
        let matchingLocalizations = matchingRequestedLanguage(
            in: localizations.keys.sorted()
        )
        guard !matchingLocalizations.isEmpty else { return nil }
        let preferredLocalizations = Bundle.preferredLocalizations(
            from: matchingLocalizations,
            forPreferences: [locale.identifier]
        )
        guard let localization = preferredLocalizations.first else {
            return nil
        }
        return localizations[localization]
    }

    /// Filters localization identifiers to the explicitly requested language.
    private func matchingRequestedLanguage(
        in localizations: [String]
    ) -> [String] {
        guard
            let requestedLanguage = languageCode(
                from: locale.identifier
            )
        else {
            return []
        }
        return localizations.filter {
            languageCode(from: $0) == requestedLanguage
        }
    }

    /// Extracts a normalized language code from a locale identifier.
    private func languageCode(from identifier: String) -> String? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        guard let language = normalized.split(separator: "-").first,
            !language.isEmpty
        else {
            return nil
        }
        return language.lowercased()
    }
}
