import Foundation

nonisolated struct WorkspaceTask: Identifiable, Codable, Equatable, Hashable, Sendable {
    static let maximumTitleCharacters = 280
    static let maximumOpenTaskCount = 200
    static let maximumArchivedTaskCount = 200
    static let maximumStoredTaskCount = maximumOpenTaskCount + maximumArchivedTaskCount

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
        self.title = Self.boundedTitle(title)
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

    static func boundedTitle(_ title: String) -> String {
        String(normalizedTitle(title).prefix(maximumTitleCharacters))
    }

    static func isValidTitle(_ title: String) -> Bool {
        let normalized = normalizedTitle(title)
        return !normalized.isEmpty && normalized.count <= maximumTitleCharacters
    }
}
