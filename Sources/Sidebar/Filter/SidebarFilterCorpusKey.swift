import CmuxWorkspaces
import Foundation

/// A cheap identity for the text the sidebar filter searches.
///
/// The prepared index is the filter's whole performance story, so it must be
/// rebuilt when the searchable text changes and never merely because a
/// workspace published something unrelated (a notification, a port, a spinner
/// tick). This key hashes exactly the fields the index reads, so an unrelated
/// change compares equal and the index survives.
struct SidebarFilterCorpusKey: Hashable {
    private let hash: Int

    /// Builds the key from the current workspaces and groups.
    ///
    /// - Parameters:
    ///   - entries: One entry per workspace, in sidebar order.
    ///   - groups: The workspace groups.
    init(entries: [SidebarFilterCorpusEntry], groups: [WorkspaceGroup]) {
        var hasher = Hasher()
        for entry in entries {
            hasher.combine(entry.workspaceId)
            hasher.combine(entry.title)
            hasher.combine(entry.branch)
            hasher.combine(entry.directory)
            hasher.combine(entry.pullRequest)
            hasher.combine(entry.ports)
            hasher.combine(entry.groupId)
            hasher.combine(entry.isGroupAnchor)
        }
        for group in groups {
            hasher.combine(group.id)
            hasher.combine(group.name)
            hasher.combine(group.anchorWorkspaceId)
        }
        self.hash = hasher.finalize()
    }
}

/// The searchable text of one workspace, extracted from the live model.
///
/// A value snapshot taken at the boundary: no `Workspace` reference reaches the
/// filter, which keeps the index pure and lets the corpus key be a plain hash.
struct SidebarFilterCorpusEntry: Hashable {
    let workspaceId: UUID
    let title: String
    let branch: String?
    let directory: String?
    let pullRequest: String?
    let ports: [String]
    let groupId: UUID?
    let isGroupAnchor: Bool
}
