import Foundation

/// Owns the provisional lifetime tokens AppKit creates before a native drag
/// session exists.
///
/// Each owner uses a private notification center, so a writer released in one
/// window cannot wake unrelated drag controllers. Controllers remove tokens
/// when AppKit promotes a writer or reports the native terminal callback; a
/// deallocation callback is therefore reserved for the abandoned pre-session
/// path.
@MainActor
final class ProvisionalDragWriterOwnership {
    /// Token retained by one provisional pasteboard writer.
    @MainActor
    final class Token {
        let id: UUID
        private let notificationCenter: NotificationCenter

        fileprivate init(notificationCenter: NotificationCenter) {
            id = UUID()
            self.notificationCenter = notificationCenter
        }

        deinit {
            notificationCenter.post(
                name: ProvisionalDragWriterOwnership.didDeallocateNotification,
                object: nil,
                userInfo: [ProvisionalDragWriterOwnership.tokenKey: id]
            )
        }
    }

    nonisolated private static let didDeallocateNotification = Notification.Name(
        "cmux.provisionalDragWriterDidDeallocate"
    )
    nonisolated private static let tokenKey = "token"

    private let notificationCenter = NotificationCenter()
    private let onTokenDeallocated: @MainActor (UUID) -> Void
    private var pendingTokenIDs: Set<UUID> = []
    private var observer: NSObjectProtocol?

    init(onTokenDeallocated: @escaping @MainActor (UUID) -> Void) {
        self.onTokenDeallocated = onTokenDeallocated
    }

    var hasPendingTokens: Bool { !pendingTokenIDs.isEmpty }

    func makeToken() -> Token {
        let token = Token(notificationCenter: notificationCenter)
        pendingTokenIDs.insert(token.id)
        installObserverIfNeeded()
        return token
    }

    func remove(_ token: Token?) {
        guard let token else { return }
        remove(id: token.id)
    }

    func remove(id: UUID) {
        pendingTokenIDs.remove(id)
        removeObserverIfIdle()
    }

    func removeAll() {
        pendingTokenIDs.removeAll(keepingCapacity: false)
        removeObserverIfIdle()
    }

    private func installObserverIfNeeded() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: Self.didDeallocateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let tokenID = notification.userInfo?[Self.tokenKey] as? UUID else { return }
            MainActor.assumeIsolated {
                guard let self, self.pendingTokenIDs.remove(tokenID) != nil else { return }
                self.removeObserverIfIdle()
                self.onTokenDeallocated(tokenID)
            }
        }
    }

    private func removeObserverIfIdle() {
        guard pendingTokenIDs.isEmpty, let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }
}
