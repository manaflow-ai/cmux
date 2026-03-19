import Foundation
import Combine

/// A writer represents a task/topic within a workspace.
/// Each writer has a t3code chat session and optional terminal splits.
final class Writer: ObservableObject, Identifiable, Codable {
    let id: UUID
    @Published var name: String
    @Published var t3codeThreadId: String?
    @Published var isActive: Bool

    /// The UUID of the ChatPanel associated with this writer, if one has been created.
    var chatPanelId: UUID?

    init(id: UUID = UUID(), name: String, t3codeThreadId: String? = nil, chatPanelId: UUID? = nil) {
        self.id = id
        self.name = name
        self.t3codeThreadId = t3codeThreadId
        self.isActive = false
        self.chatPanelId = chatPanelId
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, name, t3codeThreadId, isActive, chatPanelId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.t3codeThreadId = try container.decodeIfPresent(String.self, forKey: .t3codeThreadId)
        self.isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        self.chatPanelId = try container.decodeIfPresent(UUID.self, forKey: .chatPanelId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(t3codeThreadId, forKey: .t3codeThreadId)
        try container.encode(isActive, forKey: .isActive)
        try container.encodeIfPresent(chatPanelId, forKey: .chatPanelId)
    }
}
