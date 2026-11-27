public import CmuxMobileChanges
public import CmuxMobileRPC

// Wire-status → display-model mapping lives in the shell layer so UI packages
// consume changes model values without importing the RPC module (no UI file
// names a wire DTO type).
extension MobileWorkspaceChangeStatus {
    public var fileChangeKind: FileChangeKind {
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
