import Foundation

enum FileExplorerSortOrder: String, CaseIterable, Sendable {
    case ascending
    case descending

    init(resolvingRawValue raw: String?) {
        self = raw.flatMap { Self(rawValue: $0) } ?? .ascending
    }

    var localizedTitle: String {
        switch self {
        case .ascending:
            return String(localized: "fileExplorer.sort.order.ascending", defaultValue: "Ascending")
        case .descending:
            return String(localized: "fileExplorer.sort.order.descending", defaultValue: "Descending")
        }
    }
}
