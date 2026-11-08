public import Foundation

/// One durable entry in the task-composer drafts collection. The identity is
/// owned by the composer session that created the draft, so every leave,
/// retry, and submit of that session updates or removes the same entry
/// without touching other saved drafts.
public struct MobileTaskComposerSavedDraft: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity of this draft across saves, restores, and deletion.
    public let id: UUID
    /// Moment the draft content was last persisted.
    public var updatedAt: Date
    /// The restorable composer state exactly as last saved.
    public var content: MobileTaskComposerDraft

    /// Creates a saved draft entry.
    public init(id: UUID = UUID(), updatedAt: Date, content: MobileTaskComposerDraft) {
        self.id = id
        self.updatedAt = updatedAt
        self.content = content
    }
}

extension MobileTaskComposerDraft {
    /// Whether persisting this draft would keep nothing the user prepared.
    /// Selections alone (template, Mac, directory) are re-derived from
    /// last-used defaults, but attachments are prepared work and a
    /// completed-operation anchor must survive so recovery can still prevent
    /// a duplicate task.
    public var isEffectivelyEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (workspaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
            && completedOperationID == nil
    }
}
