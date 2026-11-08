import CmuxWorkspaces
import Foundation

/// Right-sidebar panel snapshot stored with adjacent todo persistence helpers, extracted from `SessionPersistence.swift`, which sits at its file-length budget.
struct SessionRightSidebarToolPanelSnapshot: Codable, Sendable {
    var mode: RightSidebarMode?

    init(mode: RightSidebarMode?) {
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .mode)
        self.mode = raw.flatMap { RightSidebarMode(rawValue: $0) }
    }
}

/// One persisted checklist item. Raw `state` / `origin` strings (not the
/// package enums) so a manifest written by a future build with new cases
/// still decodes here; unknown values degrade to pending/user on restore.
struct SessionChecklistItemSnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var text: String
    var state: String
    var origin: String
    var attachments: [WorkspaceChecklistAttachment] = []

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case state
        case origin
        case attachments
    }

    init(
        id: UUID,
        text: String,
        state: String,
        origin: String,
        attachments: [WorkspaceChecklistAttachment] = []
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.origin = origin
        self.attachments = attachments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.text = try container.decode(String.self, forKey: .text)
        self.state = try container.decode(String.self, forKey: .state)
        self.origin = try container.decode(String.self, forKey: .origin)
        self.attachments = (try? container.decode(LossySessionChecklistAttachments.self, forKey: .attachments))?.attachments ?? []
    }

    func encode(to encoder: any Encoder) throws {
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

extension SessionChecklistItemSnapshot {
    /// Captures a live checklist item.
    init(item: WorkspaceChecklistItem) {
        self.init(
            id: item.id,
            text: item.text,
            state: item.state.rawValue,
            origin: item.origin.rawValue,
            attachments: item.attachments
        )
    }

    /// The live item this snapshot restores to, or `nil` when the persisted
    /// text is empty after normalization. Unknown state/origin raw values
    /// degrade to `.pending` / `.user` instead of dropping the item.
    var checklistItem: WorkspaceChecklistItem? {
        guard let normalizedText = WorkspaceChecklistItem.normalizedText(text) else { return nil }
        return WorkspaceChecklistItem(
            id: id,
            text: normalizedText,
            state: WorkspaceChecklistItem.State(rawValue: state) ?? .pending,
            origin: WorkspaceChecklistItem.Origin(rawValue: origin) ?? .user,
            attachments: attachments
        )
    }
}

private struct LossySessionChecklistAttachments: Decodable {
    var attachments: [WorkspaceChecklistAttachment]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var attachments: [WorkspaceChecklistAttachment] = []
        while !container.isAtEnd {
            if let attachment = try? container.decode(WorkspaceChecklistAttachment.self) {
                attachments.append(attachment)
            } else {
                _ = try container.decode(DiscardedSessionChecklistAttachment.self)
            }
        }
        self.attachments = attachments
    }
}

private struct DiscardedSessionChecklistAttachment: Decodable {
    init(from decoder: any Decoder) throws {}
}

extension SessionWorkspaceSnapshot {
    /// Captures the live todo state into the snapshot's persisted fields.
    @MainActor
    mutating func captureTodoState(from workspace: Workspace) {
        let override = workspace.todoState.statusOverride
        taskStatusOverride = override?.status.rawValue
        taskStatusInferredAtOverride = override?.inferredAtOverride.rawValue
        taskStatusHidden = workspace.todoState.statusHidden ? true : nil
        let items = workspace.todoState.checklist
        checklist = items.isEmpty ? nil : items.map(SessionChecklistItemSnapshot.init(item:))
    }

    /// The decoded status override, or `nil` when absent or when either raw
    /// value is unknown (a partial or unparseable override is dropped whole:
    /// restoring a guessed `inferredAtOverride` would defeat anti-rot expiry).
    var restoredTaskStatusOverride: WorkspaceTaskStatusOverride? {
        guard let statusRaw = taskStatusOverride,
              let inferredRaw = taskStatusInferredAtOverride,
              let status = WorkspaceTaskStatus(rawValue: statusRaw),
              let inferredAtOverride = WorkspaceTaskStatus(rawValue: inferredRaw) else {
            return nil
        }
        return WorkspaceTaskStatusOverride(status: status, inferredAtOverride: inferredAtOverride)
    }

    /// The decoded checklist (empty for pre-feature manifests), re-applying
    /// the item cap in case the manifest was written by a build with a
    /// larger cap or edited externally.
    var restoredChecklist: [WorkspaceChecklistItem] {
        (checklist ?? [])
            .compactMap { $0.checklistItem }
            .prefix(WorkspaceChecklistItem.maxChecklistItems)
            .map { $0 }
    }
}
