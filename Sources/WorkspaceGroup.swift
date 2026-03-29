import Foundation

// MARK: - WorkspaceGroup Model

/// A named group that contains an ordered list of Workspace IDs.
/// Groups are owned by TabManager and provide a two-level sidebar hierarchy (FR3).
@MainActor
final class WorkspaceGroup: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var isCollapsed: Bool
    @Published var memberIds: [UUID]  // ordered list of Workspace IDs

    init(id: UUID = UUID(), title: String, isCollapsed: Bool = false, memberIds: [UUID] = []) {
        self.id = id
        self.title = title
        self.isCollapsed = isCollapsed
        self.memberIds = memberIds
    }
}

// MARK: - Codable Snapshot for Session Persistence

/// Lightweight, Codable representation of a WorkspaceGroup for session save/restore.
/// All fields are non-optional here because the containing field on
/// SessionTabManagerSnapshot is already declared optional for backward compatibility.
struct WorkspaceGroupSnapshot: Codable, Sendable {
    let id: UUID
    let title: String
    let isCollapsed: Bool
    let memberIds: [UUID]

    @MainActor
    init(group: WorkspaceGroup) {
        self.id = group.id
        self.title = group.title
        self.isCollapsed = group.isCollapsed
        self.memberIds = group.memberIds
    }
}
