#if os(iOS)
import Foundation

/// Resolves localized folder-child inflection markup before gallery rendering.
struct TerminalArtifactChildCountFormatter: Sendable {
    private let locale: Locale

    init(locale: Locale = .autoupdatingCurrent) {
        self.locale = locale
    }

    func string(count: Int, isCapped: Bool) -> String {
        if isCapped {
            return String(
                localized: "terminal.artifact.gallery.child_count_capped",
                defaultValue: "\(count)+ items",
                bundle: .module,
                locale: locale
            )
        }
        let attributed = AttributedString(
            localized: "terminal.artifact.gallery.child_count",
            defaultValue: "^[\(count) item](inflect: true)",
            bundle: .module,
            locale: locale
        )
        return String(attributed.characters)
    }
}
#endif
