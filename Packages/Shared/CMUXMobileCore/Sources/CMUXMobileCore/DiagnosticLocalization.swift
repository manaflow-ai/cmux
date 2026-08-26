import Foundation

/// Resolves diagnostic copy from the shared package's locale catalog.
struct DiagnosticLocalization: Sendable {
    let locale: Locale
    private let bundle: Bundle

    init(locale: Locale = .current) {
        self.locale = locale
        self.bundle = Self.bundle(for: locale)
    }

    func string(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(
            localized: key,
            defaultValue: defaultValue,
            bundle: bundle,
            locale: locale
        )
    }

    private static func bundle(for locale: Locale) -> Bundle {
        languageBundle(for: locale) ?? .module
    }

    private static func languageBundle(for locale: Locale) -> Bundle? {
        let identifiers = Bundle.preferredLocalizations(
            from: Bundle.module.localizations,
            forPreferences: [locale.identifier]
        )
        for identifier in identifiers {
            guard let path = Bundle.module.path(
                forResource: identifier,
                ofType: "lproj"
            ), let bundle = Bundle(path: path) else { continue }
            return bundle
        }
        return nil
    }
}
