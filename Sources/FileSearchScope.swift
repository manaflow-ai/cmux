import Foundation

/// The filesystem scope used by the Files and Find right-sidebar tools.
enum FileSearchScope: Equatable, Sendable {
    case unsupported
    case local
    case remoteCloud(vmID: String)

    /// Derives the search scope from the active file provider.
    init(provider: FileExplorerProvider?) {
        if provider is LocalFileExplorerProvider {
            self = .local
        } else if let cloudProvider = provider as? CloudVMFileExplorerProvider,
                  cloudProvider.isAvailable {
            self = .remoteCloud(vmID: cloudProvider.vmID)
        } else {
            self = .unsupported
        }
    }

    var debugName: String {
        switch self {
        case .unsupported: return "unsupported"
        case .local: return "local"
        case .remoteCloud: return "remoteCloud"
        }
    }

}
