import Foundation

/// Owns the provisional lifetime tokens AppKit creates before a native drag
/// session exists.
///
/// Controllers remove tokens when AppKit promotes a writer or reports the
/// native terminal callback; a deallocation callback is therefore reserved for
/// the abandoned pre-session path. The token calls back through its injected
/// owner rather than broadcasting through process-global notification state.
@MainActor
final class ProvisionalDragWriterOwnership {
    /// Token retained by one provisional pasteboard writer.
    final class Token {
        let id: UUID
        private let owner: ProvisionalDragWriterOwnership

        fileprivate init(owner: ProvisionalDragWriterOwnership) {
            id = UUID()
            self.owner = owner
        }

        /// Signals writer destruction while its controller is still retained.
        nonisolated func notifyDeallocated() {
            let owner = owner
            if Thread.isMainThread {
                // AppKit drag callbacks and writer destruction are main-thread
                // events; this keeps the normal abandonment path synchronous.
                MainActor.assumeIsolated {
                    owner.tokenDidDeallocate(id)
                }
            } else {
                // A defensive off-main release still retains the owner until
                // the actor hop executes, so cleanup cannot be lost during ARC
                // stored-property destruction.
                Task { @MainActor in
                    owner.tokenDidDeallocate(id)
                }
            }
        }

        deinit {
            // A token normally receives this signal from its writer's deinit;
            // keep this fallback for any future writer that does not explicitly
            // forward destruction. The owner-side token removal is idempotent.
            notifyDeallocated()
        }
    }

    private let onTokenDeallocated: @MainActor (UUID) -> Void
    private var pendingTokenIDs: Set<UUID> = []

    init(onTokenDeallocated: @escaping @MainActor (UUID) -> Void) {
        self.onTokenDeallocated = onTokenDeallocated
    }

    var hasPendingTokens: Bool { !pendingTokenIDs.isEmpty }

    func makeToken() -> Token {
        let token = Token(owner: self)
        pendingTokenIDs.insert(token.id)
        return token
    }

    func remove(_ token: Token?) {
        guard let token else { return }
        remove(id: token.id)
    }

    func remove(id: UUID) {
        pendingTokenIDs.remove(id)
    }

    func removeAll() {
        pendingTokenIDs.removeAll(keepingCapacity: false)
    }

    private func tokenDidDeallocate(_ tokenID: UUID) {
        guard pendingTokenIDs.remove(tokenID) != nil else { return }
        onTokenDeallocated(tokenID)
    }
}
