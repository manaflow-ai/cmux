import Foundation

nonisolated struct WorkspaceTask: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = Self.normalizedTitle(title)
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    var isArchived: Bool {
        archivedAt != nil
    }

    var isOpen: Bool {
        archivedAt == nil
    }

    static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
