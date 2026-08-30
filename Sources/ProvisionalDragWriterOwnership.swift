import Foundation

/// Owns the provisional lifetime tokens AppKit creates before a native drag
/// session exists.
///
/// Controllers remove tokens when AppKit promotes a writer or reports the
/// native terminal callback; a deallocation callback is therefore reserved for
/// the abandoned pre-session path. Each owner has a private notification
/// center, and writers post from their own `deinit` while still retaining their
/// controller, so cleanup cannot lose the owner during stored-property
/// destruction or wake unrelated windows.
@MainActor
final class ProvisionalDragWriterOwnership {
    /// Token retained by one provisional pasteboard writer.
    final class Token {
        let id: UUID
        private let notificationCenter: NotificationCenter
        // Keep the observer owner alive until the deallocation notification is
        // delivered, even if AppKit releases the writer off the main thread.
        private let owner: ProvisionalDragWriterOwnership

        fileprivate init(
            notificationCenter: NotificationCenter,
            owner: ProvisionalDragWriterOwnership
        ) {
            id = UUID()
            self.notificationCenter = notificationCenter
            self.owner = owner
        }

        /// Signals writer destruction while its controller is still retained.
        nonisolated func notifyDeallocated() {
            notificationCenter.post(
                name: ProvisionalDragWriterOwnership.didDeallocateNotification,
                object: nil,
                userInfo: [ProvisionalDragWriterOwnership.tokenKey: id]
            )
        }

        deinit {
            // A token normally receives this signal from its writer's deinit;
            // keep this fallback for any future writer that does not explicitly
            // forward destruction. The owner-side token removal is idempotent.
            notifyDeallocated()
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
        let token = Token(notificationCenter: notificationCenter, owner: self)
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
