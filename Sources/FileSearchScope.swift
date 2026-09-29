import CmuxFileSearch
import Foundation

/// The filesystem scope used by the Files and Find right-sidebar tools.
enum FileSearchScope: Equatable, Sendable {
    case unsupported
    case local
    case remoteSSH(SSHFileExplorerProvider)
    case remoteCloud(CloudVMFileExplorerProvider)

    /// Derives the search scope from the active file provider.
    init(provider: FileExplorerProvider?) {
        if provider is LocalFileExplorerProvider {
            self = .local
        } else if let sshProvider = provider as? SSHFileExplorerProvider {
            self = .remoteSSH(sshProvider)
        } else if let cloudProvider = provider as? CloudVMFileExplorerProvider {
            self = .remoteCloud(cloudProvider)
        } else {
            self = .unsupported
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
    }

    /// Stable across provider objects that name the same target, so a
    /// rebuilt provider does not restart an identical search.
    var identity: String {
        switch self {
        case .unsupported: return "unsupported"
        case .local: return "local"
        case .remoteSSH(let provider): return provider.remoteIdentity
        case .remoteCloud(let provider): return "cloud-provider:\(provider.id.uuidString)"
        }
    }

    var debugName: String {
        switch self {
        case .unsupported: return "unsupported"
        case .local: return "local"
        case .remoteSSH: return "remoteSSH"
        case .remoteCloud: return "remoteCloud"
        }
    }

    /// The backend that runs searches in this scope, or `nil` when the scope
    /// cannot be searched.
    var backend: (any FileSearchBackend)? {
        switch self {
        case .unsupported: return nil
        case .local: return LocalRipgrepFileSearchBackend()
        case .remoteSSH(let provider): return SSHRipgrepFileSearchBackend(connection: provider.connection)
        case .remoteCloud(let provider): return CloudFileSearchBackend(provider: provider)
        }
    }
}
