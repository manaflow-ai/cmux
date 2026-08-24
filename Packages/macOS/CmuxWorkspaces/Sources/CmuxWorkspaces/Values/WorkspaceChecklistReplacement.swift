public import Foundation

/// One incoming item of an atomic checklist replace (`workspace.todo.set` /
/// `cmux todo set`). Optional fields fall back per the identity-preserving
/// merge rules in `replaceChecklist(with:)`.
public struct WorkspaceChecklistReplacementItem: Sendable, Equatable {
    /// The identity to keep (when it matches an existing item) or assign.
    /// `nil` mints a fresh identity.
    public let id: UUID?
    /// The raw item text (normalized by the merge; empty is an error).
    public let text: String
    /// The state to set; `nil` keeps a matched item's state (new items
    /// default to pending).
    public let state: WorkspaceChecklistItem.State?
    /// The origin for newly created items; `nil` defaults to `.user`.
    /// Matched items always keep their existing origin.
    public let origin: WorkspaceChecklistItem.Origin?
    /// Agent task ownership to persist on the resulting row.
    public let agentTaskRef: WorkspaceAgentTaskRef?
    /// Dispatch target to persist on the resulting row.
    public let dispatchTarget: WorkspaceTaskDispatchTarget?
    /// Bound workspace id to persist on the resulting row.
    public let boundWorkspaceID: UUID?
    /// Bound agent/provider to persist on the resulting row.
    public let boundAgent: String?
    /// Last activity timestamp to persist on the resulting row.
    public let lastActivityAt: Date?

    /// Creates a replacement item.
    public init(
        id: UUID? = nil,
        text: String,
        state: WorkspaceChecklistItem.State? = nil,
        origin: WorkspaceChecklistItem.Origin? = nil,
        agentTaskRef: WorkspaceAgentTaskRef? = nil,
        dispatchTarget: WorkspaceTaskDispatchTarget? = nil,
        boundWorkspaceID: UUID? = nil,
        boundAgent: String? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.origin = origin
        self.agentTaskRef = agentTaskRef
        self.dispatchTarget = dispatchTarget
        self.boundWorkspaceID = boundWorkspaceID
        self.boundAgent = boundAgent
        self.lastActivityAt = lastActivityAt
    }
}

/// Why an atomic checklist replace was rejected (nothing is mutated).
public enum WorkspaceChecklistReplaceError: Error, Equatable, Sendable {
    /// An incoming item's text was empty after trimming (0-based index).
    case emptyText(index: Int)
    /// An incoming item repeated a non-nil identity (0-based index).
    case duplicateId(index: Int)
    /// The incoming list exceeds ``WorkspaceChecklistItem/maxChecklistItems``.
    case tooManyItems(count: Int)
}

extension Array where Element == WorkspaceChecklistItem {
    /// Atomically replaces the checklist with `items`, preserving identity
    /// and origin/attachments for incoming items whose `id` matches an existing item.
    ///
    /// Rules:
    /// - Rejects the whole replace (no mutation) when any item's text is
    ///   empty after trimming, when any non-nil id is repeated, or when
    ///   `items` exceeds the checklist cap.
    /// - Text is normalized exactly like `addChecklistItem` (trimmed, capped
    ///   at ``WorkspaceChecklistItem/maxTextLength``).
    /// - An item whose `id` matches an existing item keeps that identity,
    ///   the existing origin, and existing attachment references; its state
    ///   comes from the incoming item when given, else stays the existing state.
    /// - Any other item is created: identity from the incoming `id` (or a
    ///   fresh UUID), origin from the incoming `origin` (or `.user`), state
    ///   from the incoming `state` (or `.pending`).
    /// - Existing items not named by an incoming `id` are removed; the
    ///   result's order is the incoming order.
    ///
    /// - Parameter items: The full desired checklist.
    /// - Returns: The resulting checklist, or the rejection reason.
    @discardableResult
    public mutating func replaceChecklist(
        with items: [WorkspaceChecklistReplacementItem]
    ) -> Result<[WorkspaceChecklistItem], WorkspaceChecklistReplaceError> {
        guard items.count <= WorkspaceChecklistItem.maxChecklistItems else {
            return .failure(.tooManyItems(count: items.count))
        }
        var result: [WorkspaceChecklistItem] = []
        result.reserveCapacity(items.count)
        var seenIds = Set<UUID>()
        let existingById = Dictionary(uniqueKeysWithValues: self.map { ($0.id, $0) })
        for (index, item) in items.enumerated() {
            if let id = item.id, !seenIds.insert(id).inserted {
                return .failure(.duplicateId(index: index))
            }
            guard let normalized = WorkspaceChecklistItem.normalizedText(item.text) else {
                return .failure(.emptyText(index: index))
            }
            if let id = item.id, let existing = existingById[id] {
                result.append(WorkspaceChecklistItem(
                    id: existing.id,
                    text: normalized,
                    state: item.state ?? existing.state,
                    origin: existing.origin,
                    attachments: existing.attachments,
                    agentTaskRef: item.agentTaskRef ?? existing.agentTaskRef,
                    dispatchTarget: item.dispatchTarget ?? existing.dispatchTarget,
                    boundWorkspaceID: item.boundWorkspaceID ?? existing.boundWorkspaceID,
                    boundAgent: item.boundAgent ?? existing.boundAgent,
                    lastActivityAt: item.lastActivityAt ?? existing.lastActivityAt
                ))
            } else {
                result.append(WorkspaceChecklistItem(
                    id: item.id ?? UUID(),
                    text: normalized,
                    state: item.state ?? .pending,
                    origin: item.origin ?? .user,
                    agentTaskRef: item.agentTaskRef,
                    dispatchTarget: item.dispatchTarget,
                    boundWorkspaceID: item.boundWorkspaceID,
                    boundAgent: item.boundAgent,
                    lastActivityAt: item.lastActivityAt
                ))
            }
        }
        self = result
        return .success(result)
    }
}
