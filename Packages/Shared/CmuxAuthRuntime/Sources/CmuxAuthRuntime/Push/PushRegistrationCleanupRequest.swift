/// One direct cleanup request folded into the service's single reconciliation loop.
enum PushRegistrationCleanupRequest: Sendable {
    case live(serverMutationGeneration: UInt64)
    case captured(
        accountID: String?,
        accessToken: String?,
        refreshToken: String?,
        serverMutationGeneration: UInt64
    )
}
