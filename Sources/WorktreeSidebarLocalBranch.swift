/// Local branch metadata that controls Git's safe `branch -d` decision.
struct WorktreeSidebarLocalBranch: Equatable, Sendable {
    let name: String
    let ref: String
    let upstreamRef: String?
}
