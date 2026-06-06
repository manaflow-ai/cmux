import Foundation

struct ClosedItemHistoryRecord: Identifiable, Codable {
    let id: UUID
    let closedAt: Date
    /// Groups records closed by the same user action (a multi-select delete).
    /// A single close is a group of one (`operationId == id`). Older persisted
    /// records that predate grouping decode as singletons.
    var operationId: UUID
    var entry: ClosedItemHistoryEntry

    init(id: UUID = UUID(), closedAt: Date = Date(), operationId: UUID? = nil, entry: ClosedItemHistoryEntry) {
        self.id = id
        self.closedAt = closedAt
        self.operationId = operationId ?? id
        self.entry = entry
    }

    private enum CodingKeys: String, CodingKey {
        case id, closedAt, operationId, entry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        self.id = id
        self.closedAt = try container.decode(Date.self, forKey: .closedAt)
        self.operationId = try container.decodeIfPresent(UUID.self, forKey: .operationId) ?? id
        self.entry = try container.decode(ClosedItemHistoryEntry.self, forKey: .entry)
    }
}
