public import Foundation

/// Limits and text normalization for checklist items. These live on the item
/// type so every mutation entry point (socket verbs, CLI, sidebar UI) applies
/// them identically.
extension WorkspaceChecklistItem {
    /// The maximum number of items a checklist holds.
    public static let maxChecklistItems = 50
    /// The maximum length of one item's text; longer text is truncated.
    public static let maxTextLength = 500

    /// Why an add was rejected.
    public enum AddError: Error, Equatable, Sendable {
        /// The text was empty after trimming.
        case emptyText
        /// The checklist already holds ``maxChecklistItems`` items.
        case checklistFull
    }

    /// Trims whitespace/newlines and caps length; `nil` when nothing remains.
    ///
    /// - Parameter text: The raw item text.
    /// - Returns: The normalized text, or `nil` if empty after trimming.
    public static func normalizedText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTextLength))
    }
}

/// Value-level operations over a workspace's checklist array.
extension Array where Element == WorkspaceChecklistItem {
    /// Appends a new item after normalizing the text and checking the cap.
    ///
    /// - Parameters:
    ///   - text: The raw item text (trimmed; empty is rejected; capped at
    ///     ``WorkspaceChecklistItem/maxTextLength`` characters).
    ///   - state: The initial state.
    ///   - origin: Who created the item.
    ///   - id: The identity to assign (a fresh UUID by default).
    /// - Returns: The appended item, or the rejection reason.
    public mutating func addChecklistItem(
        _ text: String,
        state: WorkspaceChecklistItem.State = .pending,
        origin: WorkspaceChecklistItem.Origin = .user,
        id: UUID = UUID()
    ) -> Result<WorkspaceChecklistItem, WorkspaceChecklistItem.AddError> {
        guard let normalized = WorkspaceChecklistItem.normalizedText(text) else {
            return .failure(.emptyText)
        }
        guard count < WorkspaceChecklistItem.maxChecklistItems else {
            return .failure(.checklistFull)
        }
        let item = WorkspaceChecklistItem(id: id, text: normalized, state: state, origin: origin)
        append(item)
        return .success(item)
    }

    /// Sets one item's state by id.
    ///
    /// - Parameters:
    ///   - id: The item to update.
    ///   - state: The new state.
    /// - Returns: `true` if the item existed.
    @discardableResult
    public mutating func setChecklistItemState(
        id: UUID,
        state: WorkspaceChecklistItem.State
    ) -> Bool {
        guard let index = firstIndex(where: { $0.id == id }) else { return false }
        self[index].state = state
        return true
    }

    /// Rewrites one item's text by id, applying the same normalization as
    /// ``addChecklistItem(_:state:origin:id:)``.
    ///
    /// - Parameters:
    ///   - id: The item to edit.
    ///   - text: The replacement text (trimmed; empty is rejected; capped at
    ///     ``WorkspaceChecklistItem/maxTextLength`` characters).
    /// - Returns: `true` if the item existed and the text was non-empty.
    @discardableResult
    public mutating func setChecklistItemText(id: UUID, text: String) -> Bool {
        guard let normalized = WorkspaceChecklistItem.normalizedText(text),
              let index = firstIndex(where: { $0.id == id }) else { return false }
        self[index].text = normalized
        return true
    }

    /// Removes one item by id.
    ///
    /// - Parameter id: The item to remove.
    /// - Returns: `true` if the item existed.
    @discardableResult
    public mutating func removeChecklistItem(id: UUID) -> Bool {
        guard let index = firstIndex(where: { $0.id == id }) else { return false }
        remove(at: index)
        return true
    }

    /// Removes every item.
    ///
    /// - Returns: The number of items removed.
    @discardableResult
    public mutating func clearChecklist() -> Int {
        let removed = count
        removeAll()
        return removed
    }

    /// The progress readout of the checklist.
    public var checklistProgressSummary: WorkspaceChecklistProgressSummary {
        WorkspaceChecklistProgressSummary(
            completedCount: count(where: { $0.state == .completed }),
            totalCount: count,
            firstUncheckedText: first(where: { $0.state != .completed })?.text
        )
    }
}
