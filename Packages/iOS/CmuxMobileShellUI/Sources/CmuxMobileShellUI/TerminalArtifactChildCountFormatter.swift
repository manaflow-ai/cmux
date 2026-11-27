#if os(iOS)
import Foundation

/// Resolves localized folder-child inflection markup before gallery rendering.
struct TerminalArtifactChildCountFormatter: Sendable {
    private let locale: Locale
    private let bundle: Bundle

    init(locale: Locale = .autoupdatingCurrent) {
        self.locale = locale
        self.bundle = Self.bundle(for: locale)
    }

    func string(count: Int, isCapped: Bool) -> String {
        if isCapped {
            return String(
                localized: "terminal.artifact.gallery.child_count_capped",
                defaultValue: "\(count)+ items",
                bundle: bundle,
                locale: locale
            )
        }
        let attributed = AttributedString(
            localized: "terminal.artifact.gallery.child_count",
            defaultValue: "^[\(count) item](inflect: true)",
            bundle: bundle,
            locale: locale
        )
        return String(attributed.characters)
    }

    /// The `locale:` argument only formats interpolations; the string table
    /// still follows the process language. Pick the matching `.lproj` so an
    /// injected locale also selects its translation.
    private static func bundle(for locale: Locale) -> Bundle {
        let identifiers = Bundle.preferredLocalizations(
            from: Bundle.module.localizations,
            forPreferences: [locale.identifier]
        )
        for identifier in identifiers {
            guard let path = Bundle.module.path(forResource: identifier, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            return bundle
        }
        return .module
    }
}
#endif
