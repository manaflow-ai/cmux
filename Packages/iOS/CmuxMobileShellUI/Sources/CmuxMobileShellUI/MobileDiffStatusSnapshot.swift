import CmuxMobileRPC
import CmuxMobileShell
import Foundation

/// Native projection of one workspace Git-status response.
struct MobileDiffStatusSnapshot: Equatable, Sendable {
    let repoRoot: String
    let files: [MobileDiffFileChange]
    let totalAdditions: Int
    let totalDeletions: Int

    init(
        repoRoot: String,
        files: [MobileDiffFileChange],
        totalAdditions: Int,
        totalDeletions: Int
    ) {
        self.repoRoot = repoRoot
        self.files = files
        self.totalAdditions = totalAdditions
        self.totalDeletions = totalDeletions
    }

    init(_ response: MobileSyncGitStatusResponse) {
        self.init(
            repoRoot: response.repoRoot,
            files: response.files.map(MobileDiffFileChange.init),
            totalAdditions: response.totalAdditions,
            totalDeletions: response.totalDeletions
        )
    }
}
