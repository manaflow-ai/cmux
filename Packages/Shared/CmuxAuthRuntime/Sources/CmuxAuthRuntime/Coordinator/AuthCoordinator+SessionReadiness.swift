extension AuthCoordinator {
    /// The session as token consumers see it. Work that needs the signed-in
    /// session's tokens (registering an install, listing machines) waits for
    /// `.ready` instead of ``isAuthenticated``.
    public var sessionReadiness: AuthSessionReadiness {
        guard isAuthenticated else { return .signedOut }
        return .ready(accountID: currentUser?.id ?? "")
    }
}
