import CmuxMobileChanges
import CmuxMobileShell

extension MobileWorkspaceChangeStatus {
    var fileChangeKind: FileChangeKind {
        switch self {
        case .added: .added
        case .modified: .modified
        case .deleted: .deleted
        case .renamed: .renamed
        case .untracked: .untracked
        case .unknown: .unknown
        }
    }
}
