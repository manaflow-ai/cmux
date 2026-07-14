import Foundation

/// The two projections available inside the unified file explorer host.
enum FileExplorerSearchScope: Int, Sendable {
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

}
