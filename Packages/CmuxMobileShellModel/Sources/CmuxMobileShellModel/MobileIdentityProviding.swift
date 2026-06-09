/// A seam exposing the signed-in user's stable identifier to the shell layer.
///
/// The shell tags persisted paired-Mac records with the current Stack user id so
/// reconnect-on-launch only restores macs the same account paired. Depending on
/// `any MobileIdentityProviding` keeps the shell off the auth singleton; the app
/// constructs a concrete conformer over its auth manager at the composition root
/// and injects it.
public protocol MobileIdentityProviding: Sendable {
    /// The current signed-in user's stable identifier, or `nil` when signed out.
    @MainActor var currentUserID: String? { get }
}
