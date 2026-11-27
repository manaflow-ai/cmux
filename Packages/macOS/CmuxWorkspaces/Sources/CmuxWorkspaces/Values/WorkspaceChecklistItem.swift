public import Foundation

/// One task item in a workspace's persisted checklist, writable by the user
/// (sidebar, CLI) and by agents (control socket). Raw values of the nested
/// enums are a control-socket and session wire format; frozen.
public struct WorkspaceChecklistItem: Codable, Sendable, Identifiable, Hashable {
    /// The item's completion state.
    public enum State: String, Codable, Sendable, CaseIterable {
        case pending
        case inProgress = "in-progress"
        case completed
    }

    /// Who created the item.
    public enum Origin: String, Codable, Sendable, CaseIterable {
        case user
        case agent
    }

    /// The item's stable identity.
    public var id: UUID
    /// The task text (trimmed, non-empty, capped by ``WorkspaceChecklist``).
    public var text: String
    /// The completion state.
    public var state: State
    /// Who created the item.
    public var origin: Origin
    /// User-owned image files attached to the item.
    public var attachments: [WorkspaceChecklistAttachment]

    /// Number of attachments available for compact UI counts.
    public var attachmentCount: Int {
        attachments.count
    }

    /// Creates an item.
    public init(
        id: UUID = UUID(),
        text: String,
        state: State = .pending,
        origin: Origin = .user,
        attachments: [WorkspaceChecklistAttachment] = []
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.origin = origin
        self.attachments = attachments
    }

    /// Checks whether any attachment file is currently missing.
    public func hasMissingAttachments(fileManager: FileManager = .default) -> Bool {
        attachments.contains { $0.isMissing(fileManager: fileManager) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case state
        case origin
        case attachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.text = try container.decode(String.self, forKey: .text)
        self.state = try container.decode(State.self, forKey: .state)
        self.origin = try container.decode(Origin.self, forKey: .origin)
        self.attachments = (try? container.decode(LossyWorkspaceChecklistAttachments.self, forKey: .attachments))?.attachments ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(state, forKey: .state)
        try container.encode(origin, forKey: .origin)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
    }
}

private struct LossyWorkspaceChecklistAttachments: Decodable {
    var attachments: [WorkspaceChecklistAttachment]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var attachments: [WorkspaceChecklistAttachment] = []
        while !container.isAtEnd {
            if let attachment = try? container.decode(WorkspaceChecklistAttachment.self) {
                attachments.append(attachment)
            } else {
                _ = try container.decode(DiscardedChecklistAttachment.self)
            }
        }
        self.attachments = attachments
    }
}

private struct DiscardedChecklistAttachment: Decodable {
    init(from decoder: any Decoder) throws {}
}
