/// Visual presentation of the shared file explorer host.
enum FileExplorerPanelPresentation: Equatable {
    case unified
    case files
    case find

    var rightSidebarMode: RightSidebarMode {
        switch self {
        case .unified, .files: .files
        case .find: .find
        }
    }

    var keepsSearchFieldVisible: Bool {
        self == .unified
    }
}
