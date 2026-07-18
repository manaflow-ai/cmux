import Foundation

/// One normalized branch and working-directory row shared by both sidebar renderers.
struct SidebarWorkspaceBranchDirectoryRowContent: Equatable {
    let branch: String?
    let directoryCandidates: [String]
    let stacksBranchAndDirectory: Bool
}
