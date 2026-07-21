#if os(iOS)
import Foundation

/// Resolves localized folder-child inflection markup before gallery rendering.
struct TerminalArtifactChildCountFormatter: Sendable {
    private let locale: Locale

    init(locale: Locale = .autoupdatingCurrent) {
        self.locale = locale
    }

    func string(count: Int, isCapped: Bool) -> String {
        let bundle = localizedBundle
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

    private var localizedBundle: Bundle {
        guard let languageCode = locale.language.languageCode?.identifier,
              let url = Bundle.module.url(forResource: languageCode, withExtension: "lproj"),
              let bundle = Bundle(url: url) else {
            return .module
        }
        return bundle
    }
}
#endif
