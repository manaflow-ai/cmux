import Foundation

/// Shallow filesystem boundaries that can change Git's registered worktree list.
struct WorktreeSidebarListingWatchPlan: Equatable, Sendable {
    static let empty = WorktreeSidebarListingWatchPlan(
        membershipDirectory: nil,
        metadataPaths: []
    )

    let membershipDirectory: String?
    let metadataPaths: [String]

    var shallowPaths: [String] {
        Array(Set(metadataPaths + [membershipDirectory].compactMap { $0 })).sorted()
    }
}
