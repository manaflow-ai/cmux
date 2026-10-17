import Foundation

/// Deterministic client-side reconciliation for the chat session list.
///
/// The host may replay, reorder, or duplicate descriptor pushes around a
/// reconnect. This reducer keeps one descriptor per stable session id, applies
/// only newer revisions, and preserves a stable activity ordering.
public struct ChatSessionReconciler: Sendable, Equatable {
    private var descriptorsByID: [String: ChatSessionDescriptor] = [:]
    /// A removal is a tombstone, rather than just a missing dictionary row.
    /// Without it, an older descriptor push can resurrect a session after the
    /// host has authoritatively removed it.
    private var removedVersionByID: [String: Int] = [:]
    /// Monotonic local mutation cursor used to distinguish a descriptor that
    /// was already present when a snapshot started from one pushed while that
    /// snapshot request was in flight.
    private var mutationRevision: UInt64 = 0
    private var lastMutationRevisionByID: [String: UInt64] = [:]

    public init() {}

    /// The current descriptors ordered for the session picker.
    public var descriptors: [ChatSessionDescriptor] {
        ChatSessionDescriptor.openable(Array(descriptorsByID.values))
    }

    /// Cursor to capture immediately before an authoritative snapshot request.
    /// Pass it back to ``replace(with:capturedAt:)`` after the request returns.
    /// Mutations observed after the cursor survive a snapshot that did not yet
    /// include them.
    public var snapshotRevision: UInt64 { mutationRevision }

    /// Replaces the authoritative list returned by `mobile.chat.sessions`.
    /// Existing descriptors are retained only when the host returned a newer
    /// snapshot for the same id, or when a newer local push was applied after
    /// the request began. This prevents an in-flight snapshot from erasing a
    /// live push that arrived during the request.
    public mutating func replace(
        with incoming: [ChatSessionDescriptor],
        capturedAt snapshotRevision: UInt64? = nil
    ) {
        let snapshotRevision = snapshotRevision ?? mutationRevision
        var incomingIDs = Set<String>()
        for descriptor in incoming {
            upsert(descriptor)
            if descriptorsByID[descriptor.id] != nil {
                incomingIDs.insert(descriptor.id)
            }
        }
        descriptorsByID = descriptorsByID.filter { id, _ in
            incomingIDs.contains(id)
                || (lastMutationRevisionByID[id] ?? 0) > snapshotRevision
        }
    }

    /// Applies one authoritative descriptor snapshot.
    @discardableResult
    public mutating func upsert(_ descriptor: ChatSessionDescriptor) -> Bool {
        guard descriptor.version > (removedVersionByID[descriptor.id] ?? Int.min) else {
            return false
        }
        guard let existing = descriptorsByID[descriptor.id] else {
            descriptorsByID[descriptor.id] = descriptor
            recordMutation(for: descriptor.id)
            return true
        }
        guard descriptor.version >= existing.version else { return false }
        if descriptor == existing { return false }
        descriptorsByID[descriptor.id] = descriptor
        recordMutation(for: descriptor.id)
        return true
    }

    /// Applies a session event to the descriptor list. Message events are
    /// intentionally ignored; they are owned by the selected conversation.
    @discardableResult
    public mutating func apply(sessionID: String, event: ChatSessionEvent) -> Bool {
        switch event {
        case .descriptorChanged(let descriptor):
            return upsert(descriptor)
        case .stateChanged(let state, let version):
            guard var descriptor = descriptorsByID[sessionID] else { return false }
            guard descriptor.state != state else { return false }
            let nextVersion = version ?? (descriptor.version + 1)
            guard nextVersion > descriptor.version else { return false }
            descriptor = descriptor.withState(state)
            descriptor.version = nextVersion
            return upsert(descriptor)
        case .sessionRemoved(let version):
            if let existing = descriptorsByID[sessionID], version < existing.version {
                return false
            }
            let previousRemoval = removedVersionByID[sessionID] ?? Int.min
            guard version > previousRemoval else { return false }
            removedVersionByID[sessionID] = version
            let removed = descriptorsByID.removeValue(forKey: sessionID) != nil
            recordMutation(for: sessionID)
            return removed
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
        let existing = descriptorsByID.removeValue(forKey: id)
        let version = existing?.version ?? (removedVersionByID[id] ?? Int.min)
        let previousRemoval = removedVersionByID[id] ?? Int.min
        if version > previousRemoval {
            removedVersionByID[id] = version
            recordMutation(for: id)
        }
        return existing != nil
    }

    private mutating func recordMutation(for id: String) {
        mutationRevision &+= 1
        lastMutationRevisionByID[id] = mutationRevision
    }
}
