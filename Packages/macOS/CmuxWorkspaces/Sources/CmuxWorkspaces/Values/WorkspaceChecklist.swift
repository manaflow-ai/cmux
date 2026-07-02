public import Foundation

/// Value-level operations over a workspace's checklist array. All mutation
/// entry points (socket verbs, CLI, sidebar UI) funnel through these so the
/// caps and text normalization apply identically everywhere.
public enum WorkspaceChecklist {
    /// The maximum number of items a checklist holds.
    public static let maxItems = 50
    /// The maximum length of one item's text; longer text is truncated.
    public static let maxTextLength = 500

    /// Why an add was rejected.
    public enum AddError: Error, Equatable, Sendable {
        /// The text was empty after trimming.
        case emptyText
        /// The checklist already holds ``maxItems`` items.
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

    /// Appends a new item after normalizing the text and checking the cap.
    ///
    /// - Parameters:
    ///   - text: The raw item text (trimmed; empty is rejected; capped at
    ///     ``maxTextLength`` characters).
    ///   - state: The initial state.
    ///   - origin: Who created the item.
    ///   - id: The identity to assign (a fresh UUID by default).
    ///   - items: The checklist to mutate.
    /// - Returns: The appended item, or the rejection reason.
    public static func add(
        _ text: String,
        state: WorkspaceChecklistItem.State = .pending,
        origin: WorkspaceChecklistItem.Origin = .user,
        id: UUID = UUID(),
        to items: inout [WorkspaceChecklistItem]
    ) -> Result<WorkspaceChecklistItem, AddError> {
        guard let normalized = normalizedText(text) else {
            return .failure(.emptyText)
        }
        guard items.count < maxItems else {
            return .failure(.checklistFull)
        }
        let item = WorkspaceChecklistItem(id: id, text: normalized, state: state, origin: origin)
        items.append(item)
        return .success(item)
    }

    /// Sets one item's state by id.
    ///
    /// - Parameters:
    ///   - id: The item to update.
    ///   - state: The new state.
    ///   - items: The checklist to mutate.
    /// - Returns: `true` if the item existed.
    @discardableResult
    public static func setState(
        id: UUID,
        state: WorkspaceChecklistItem.State,
        in items: inout [WorkspaceChecklistItem]
    ) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].state = state
        return true
    }

    /// Removes one item by id.
    ///
    /// - Parameters:
    ///   - id: The item to remove.
    ///   - items: The checklist to mutate.
    /// - Returns: `true` if the item existed.
    @discardableResult
    public static func remove(
        id: UUID,
        from items: inout [WorkspaceChecklistItem]
    ) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        return true
    }

    /// Removes every item.
    ///
    /// - Parameter items: The checklist to mutate.
    /// - Returns: The number of items removed.
    @discardableResult
    public static func clear(_ items: inout [WorkspaceChecklistItem]) -> Int {
        let removed = items.count
        items.removeAll()
        return removed
    }

    /// A compact progress readout for sidebar rows and CLI output.
    public struct ProgressSummary: Equatable, Sendable {
        /// How many items are completed.
        public let completedCount: Int
        /// How many items exist.
        public let totalCount: Int
        /// The text of the first item that is not completed, if any.
        public let firstUncheckedText: String?

        /// Creates a summary.
        public init(completedCount: Int, totalCount: Int, firstUncheckedText: String?) {
            self.completedCount = completedCount
            self.totalCount = totalCount
            self.firstUncheckedText = firstUncheckedText
        }
    }

    /// The progress readout of a checklist.
    ///
    /// - Parameter items: The checklist to summarize.
    /// - Returns: Completed/total counts and the first unchecked item's text.
    public static func progressSummary(of items: [WorkspaceChecklistItem]) -> ProgressSummary {
        ProgressSummary(
            completedCount: items.count(where: { $0.state == .completed }),
            totalCount: items.count,
            firstUncheckedText: items.first(where: { $0.state != .completed })?.text
        )
    }
}
