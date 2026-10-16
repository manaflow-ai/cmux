import Foundation

/// Resolves diagnostic copy from the shared package's locale catalog.
struct DiagnosticLocalization: Sendable {
    private final class BundleFinder {}

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
        languageBundle(for: locale) ?? packageResourceBundle ?? .main
    }

    private static func languageBundle(for locale: Locale) -> Bundle? {
        guard let packageResourceBundle else { return nil }
        let identifiers = Bundle.preferredLocalizations(
            from: packageResourceBundle.localizations,
            forPreferences: [locale.identifier]
        )
        for identifier in identifiers {
            guard let path = packageResourceBundle.path(
                forResource: identifier,
                ofType: "lproj"
            ), let bundle = Bundle(path: path) else { continue }
            return bundle
        }
        return nil
    }

    /// SwiftPM normally synthesizes `Bundle.module` for this lookup. That
    /// accessor traps when a tagged app is replaced while its previous process
    /// is still starting, because the old process can briefly observe a bundle
    /// whose package resources have moved. Keep the lookup optional so
    /// diagnostics fall back to their supplied English defaults instead of
    /// turning startup telemetry into a process-wide fatal error.
    private static let packageResourceBundle: Bundle? = {
        let bundleName = "CMUXMobileCore_CMUXMobileCore"
        let resourceRoots = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
        ]
        for root in resourceRoots {
            guard let root else { continue }
            let url = root.appendingPathComponent(bundleName + ".bundle")
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()
}
