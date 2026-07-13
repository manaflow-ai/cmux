import CmuxMobileRPC
import CmuxMobileShell
import Foundation

/// Immutable file-change snapshot used by the native changes tree.
struct MobileDiffFileChange: Identifiable, Equatable, Sendable {
    var id: String { path }

    let path: String
    let oldPath: String?
    let status: String
    let additions: Int
    let deletions: Int
    let binary: Bool
    let untracked: Bool

    init(
        path: String,
        oldPath: String? = nil,
        status: String,
        additions: Int,
        deletions: Int,
        binary: Bool = false,
        untracked: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.binary = binary
        self.untracked = untracked
    }

    init(_ file: MobileSyncGitStatusFile) {
        self.init(
            path: file.path,
            oldPath: file.oldPath,
            status: file.status,
            additions: file.additions,
            deletions: file.deletions,
            binary: file.binary,
            untracked: file.untracked
        )
    }
}
