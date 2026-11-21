import Foundation

/// Sort direction for the file explorer. Raw values match the `fileExplorer.sortOrder` values in `cmux.json`.
enum FileExplorerSortOrder: String, CaseIterable, Sendable {
    case ascending
    case descending

    /// Parses a stored or configured value, falling back to `.ascending` for a missing or unknown value.
    init(resolvingRawValue raw: String?) {
        self = raw.flatMap { Self(rawValue: $0) } ?? .ascending
    }

    /// Title shown in the header sort menu and tooltip.
    var localizedTitle: String {
        switch self {
        case .ascending:
            return String(localized: "fileExplorer.sort.order.ascending", defaultValue: "Ascending")
        case .descending:
            return String(localized: "fileExplorer.sort.order.descending", defaultValue: "Descending")
        }
    }
}
