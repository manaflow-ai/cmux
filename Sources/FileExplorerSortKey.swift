import Foundation

/// The attribute the file explorer orders entries by. Raw values match the `fileExplorer.sortBy` values in `cmux.json`.
enum FileExplorerSortKey: String, CaseIterable, Sendable {
    case name
    case dateCreated
    case dateModified

    /// Parses a stored or configured value, falling back to `.name` for a missing or unknown value.
    init(resolvingRawValue raw: String?) {
        self = raw.flatMap { Self(rawValue: $0) } ?? .name
    }

    /// Title shown in the header sort menu and tooltip.
    var localizedTitle: String {
        switch self {
        case .name:
            return String(localized: "fileExplorer.sort.key.name", defaultValue: "Name")
        case .dateCreated:
            return String(localized: "fileExplorer.sort.key.dateCreated", defaultValue: "Date Created")
        case .dateModified:
            return String(localized: "fileExplorer.sort.key.dateModified", defaultValue: "Date Modified")
        }
    }
}
