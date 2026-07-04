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

    /// The current signed-in user's primary email, or `nil` when signed out or
    /// when no email is set on the account.
    ///
    /// The Send Feedback router reads this to decide whether the privileged
    /// direct-to-agent path applies (`@manaflow.ai`); it is also the default
    /// reply-to address when emailing the feedback inbox.
    @MainActor var currentUserEmail: String? { get }

    /// Whether ``currentUserID`` is minted by cmux's development auth
    /// environment rather than production.
    @MainActor var isDevelopmentAuthEnvironment: Bool { get }
}

public extension MobileIdentityProviding {
    /// Default so existing conformers (and test doubles) that only model the
    /// user id keep compiling; they report no email and therefore route to the
    /// email path, which is the safe fallback.
    @MainActor var currentUserEmail: String? { nil }

    /// Default `false` (production): conformers and test doubles model
    /// release-channel identities unless they opt in.
    @MainActor var isDevelopmentAuthEnvironment: Bool { false }
}
