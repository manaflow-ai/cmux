import Foundation

enum FileExplorerSortKey: String, CaseIterable, Sendable {
    case name
    case dateCreated
    case dateModified

    init(resolvingRawValue raw: String?) {
        self = raw.flatMap { Self(rawValue: $0) } ?? .name
    }

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
