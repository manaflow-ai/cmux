import Foundation

/// Resolves diagnostic copy from the shared package's locale catalog.
struct DiagnosticLocalization: Sendable {
    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func string(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(
            localized: key,
            defaultValue: defaultValue,
            bundle: .module,
            locale: locale
        )
    }
}
