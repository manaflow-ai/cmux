import Foundation

/// Deterministic client-side reconciliation for the chat session list.
///
/// The host may replay, reorder, or duplicate descriptor pushes around a
/// reconnect. This reducer keeps one descriptor per stable session id, applies
/// only newer revisions, and preserves a stable activity ordering.
public struct ChatSessionReconciler: Sendable, Equatable {
    private var descriptorsByID: [String: ChatSessionDescriptor] = [:]

    public init() {}

    /// The current descriptors ordered for the session picker.
    public var descriptors: [ChatSessionDescriptor] {
        ChatSessionDescriptor.openable(Array(descriptorsByID.values))
    }

    /// Replaces the authoritative list returned by `mobile.chat.sessions`.
    /// Existing descriptors are retained only when the host returned a newer
    /// snapshot for the same id; this prevents a stale list response from
    /// erasing a live push that arrived while the request was in flight.
    public mutating func replace(with incoming: [ChatSessionDescriptor]) {
        for descriptor in incoming {
            upsert(descriptor)
        }
        let incomingIDs = Set(incoming.map(\.id))
        descriptorsByID = descriptorsByID.filter { incomingIDs.contains($0.key) }
    }

    /// Applies one authoritative descriptor snapshot.
    @discardableResult
    public mutating func upsert(_ descriptor: ChatSessionDescriptor) -> Bool {
        guard let existing = descriptorsByID[descriptor.id] else {
            descriptorsByID[descriptor.id] = descriptor
            return true
        }
        guard descriptor.version >= existing.version else { return false }
        if descriptor == existing { return false }
        descriptorsByID[descriptor.id] = descriptor
        return true
    }

    /// Applies a session event to the descriptor list. Message events are
    /// intentionally ignored; they are owned by the selected conversation.
    @discardableResult
    public mutating func apply(sessionID: String, event: ChatSessionEvent) -> Bool {
        switch event {
        case .descriptorChanged(let descriptor):
            return upsert(descriptor)
        case .stateChanged(let state):
            guard var descriptor = descriptorsByID[sessionID] else { return false }
            guard descriptor.state != state else { return false }
            descriptor = descriptor.withState(state)
            descriptor.version += 1
            return upsert(descriptor)
        case .sessionRemoved(let version):
            guard let existing = descriptorsByID[sessionID], version >= existing.version else {
                return false
            }
            return descriptorsByID.removeValue(forKey: sessionID) != nil
        case .reset, .appended, .updated, .terminalBlocks, .streamingProse, .unknown:
            return false
        }
    }

    /// Returns a descriptor by stable session id.
    public func descriptor(for id: String) -> ChatSessionDescriptor? {
        descriptorsByID[id]
    }

    /// Drops one session after a `not_found` response or a removal push.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        descriptorsByID.removeValue(forKey: id) != nil
    }
}
