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
    typealias Token = ProvisionalDragWriterOwnershipToken

    private let onTokenDeallocated: @MainActor (UUID) -> Void
    private var pendingTokenIDs: Set<UUID> = []

    init(onTokenDeallocated: @escaping @MainActor (UUID) -> Void) {
        self.onTokenDeallocated = onTokenDeallocated
    }

    var hasPendingTokens: Bool { !pendingTokenIDs.isEmpty }

    func makeToken() -> Token {
        let token = Token { [weak self] tokenID in
            self?.tokenDidDeallocate(tokenID)
        }
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
