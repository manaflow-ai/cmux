import Foundation

/// A named sidebar section and the agent statuses assigned to it.
struct CmuxSessionStatusGroupDefinition: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let statuses: [SessionCardSnapshot.Status]

    init(id: String, title: String, statuses: [SessionCardSnapshot.Status]) {
        self.id = id
        self.title = title
        self.statuses = statuses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = try container.decode(String.self, forKey: .title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "sidebar session status group ids may contain letters, numbers, dots, underscores, and hyphens"
            )
        }
        guard id != SessionCardGroup.pinnedID, id != SessionCardGroup.otherID else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "sidebar session status group ids 'pinned' and 'other' are reserved"
            )
        }
        guard !title.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "sidebar session status group titles must not be blank"
            )
        }
        let statuses = try container.decode([SessionCardSnapshot.Status].self, forKey: .statuses)
        guard !statuses.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .statuses,
                in: container,
                debugDescription: "sidebar session status groups must contain at least one status"
            )
        }
        guard Set(statuses).count == statuses.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .statuses,
                in: container,
                debugDescription: "sidebar session status groups must not repeat a status"
            )
        }
        self.id = id
        self.title = title
        self.statuses = statuses
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(statuses, forKey: .statuses)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case statuses
    }
}
