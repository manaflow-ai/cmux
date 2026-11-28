import Foundation

@testable import CMUXMobileCore

struct LocalizationTestSupport {
    private let bundle: Bundle

    init(bundle: Bundle = .module) {
        self.bundle = bundle
    }

    /// Command-line SwiftPM copies `.xcstrings` without compiling locale
    /// resources. Xcode builds emit the `.lproj` bundles these tests exercise.
    func hasCompiledLocalization(for locale: Locale) -> Bool {
        let identifiers = Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: [locale.identifier]
        )
        return identifiers.contains { identifier in
            bundle.path(forResource: identifier, ofType: "lproj") != nil
        }
    }
}
