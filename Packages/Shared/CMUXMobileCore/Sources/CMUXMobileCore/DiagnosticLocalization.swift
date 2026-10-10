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
    ///
    /// The roots are the ones the synthesized accessor searches: the app's
    /// resources, the bundle that holds this module (a framework), the app
    /// bundle itself, and the directory that contains this module's bundle.
    /// Under `swift test` the resource bundle sits beside the `.xctest`
    /// bundle, so without that last root every localized string fell back to
    /// English there.
    private static let packageResourceBundle: Bundle? = {
        let bundleName = "CMUXMobileCore_CMUXMobileCore"
        let moduleBundle = Bundle(for: BundleFinder.self)
        let resourceRoots = [
            Bundle.main.resourceURL,
            moduleBundle.resourceURL,
            Bundle.main.bundleURL,
            moduleBundle.bundleURL.deletingLastPathComponent(),
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
