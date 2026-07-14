import Foundation

/// The two search projections available inside the unified file explorer.
enum FileExplorerSearchScope: Int, CaseIterable, Sendable {
    case names
    case contents

    init(mode: RightSidebarMode) {
        self = mode == .find ? .contents : .names
    }

    var activationMode: RightSidebarMode {
        switch self {
        case .names: .files
        case .contents: .find
        }
    }

    var title: String {
        switch self {
        case .names:
            String(localized: "fileExplorer.search.scope.names", defaultValue: "Names")
        case .contents:
            String(localized: "fileExplorer.search.scope.contents", defaultValue: "Contents")
        }
    }

    var placeholder: String {
        switch self {
        case .names:
            String(localized: "fileExplorer.search.placeholder.names", defaultValue: "Find files")
        case .contents:
            String(localized: "fileExplorer.search.placeholder.contents", defaultValue: "Search contents")
        }
    }
}
