import Combine
import SwiftUI

/// A user-defined collapsible group in the sidebar.
/// Section membership is stored as ordered workspace UUIDs here, not on the Workspace model.
@MainActor
final class SidebarSection: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String
    @Published var isCollapsed: Bool
    @Published var workspaceIds: [UUID]

    /// Monotonically increasing revision counter. Bumped on every mutation so
    /// parent views that read this value (via the TabManager computed layout)
    /// re-evaluate even when the `sections` array identity hasn't changed.
    @Published var revision: UInt64 = 0

    init(id: UUID = UUID(), name: String, isCollapsed: Bool = false, workspaceIds: [UUID] = []) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.workspaceIds = workspaceIds
    }

    private func bumpRevision() {
        revision &+= 1
    }

    func contains(_ workspaceId: UUID) -> Bool {
        workspaceIds.contains(workspaceId)
    }

    func removeWorkspace(_ workspaceId: UUID) {
        workspaceIds.removeAll { $0 == workspaceId }
        bumpRevision()
    }

    func addWorkspace(_ workspaceId: UUID, at index: Int? = nil) {
        // Remove first to prevent duplicates
        workspaceIds.removeAll { $0 == workspaceId }
        if let index, index >= 0, index <= workspaceIds.count {
            workspaceIds.insert(workspaceId, at: index)
        } else {
            workspaceIds.append(workspaceId)
        }
        bumpRevision()
    }

    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        bumpRevision()
    }

    func toggleCollapsed() {
        isCollapsed.toggle()
        bumpRevision()
    }
}

// MARK: - Sidebar Layout

/// Computed layout for sidebar rendering. Separates pinned workspaces, ungrouped workspaces,
/// and section groups into a single structure consumed by VerticalTabsSidebar.
struct SidebarLayout {
    struct SectionGroup {
        let section: SidebarSection
        let workspaces: [Workspace]
    }

    let pinnedWorkspaces: [Workspace]
    let ungroupedWorkspaces: [Workspace]
    let sectionGroups: [SectionGroup]

    /// All workspaces in sidebar display order: pinned, ungrouped, then section contents.
    var allWorkspacesInOrder: [Workspace] {
        pinnedWorkspaces + ungroupedWorkspaces + sectionGroups.flatMap(\.workspaces)
    }

    /// Empty layout with no workspaces or sections.
    static let empty = SidebarLayout(pinnedWorkspaces: [], ungroupedWorkspaces: [], sectionGroups: [])
}
