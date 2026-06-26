/// Public magic-link state exposed to auth UI surfaces.
public extension AuthCoordinator {
    /// Whether the coordinator currently has a nonce that can verify an emailed code.
    var hasPendingMagicLinkCode: Bool {
        pendingNonce != nil
    }
}
