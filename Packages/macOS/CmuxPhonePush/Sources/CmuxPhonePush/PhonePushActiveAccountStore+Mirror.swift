public import CmuxAuthRuntime

extension PhonePushActiveAccountStore {
    /// Keeps the marker equal to the signed-in account for as long as
    /// `identities` runs. The auth stream yields the current state first, so a
    /// launch that restores a cached session writes the marker without a new
    /// sign-in; the notification service extension cannot decrypt without it.
    public func mirror(_ identities: AsyncStream<AuthenticatedSessionIdentity?>) async {
        for await identity in identities {
            if let accountID = identity?.accountID, !accountID.isEmpty {
                set(accountID)
            } else {
                clear()
            }
        }
    }
}
