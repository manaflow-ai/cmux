public extension AuthCoordinator {
    var hasPendingMagicLinkCode: Bool {
        pendingNonce != nil
    }
}
