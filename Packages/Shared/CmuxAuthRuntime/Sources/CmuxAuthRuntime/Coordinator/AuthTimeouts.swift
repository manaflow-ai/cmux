import Foundation

/// Per-phase deadlines for the sign-in and session flows the
/// ``AuthCoordinator`` drives.
///
/// Every phase that holds a user-visible loading state is raced against one of
/// these deadlines on the coordinator's injected clock, so no flow can leave
/// the UI spinning forever: a phase that neither completes nor fails by its
/// deadline ends as ``AuthError/timedOut`` (localized, retryable). Tests
/// exercise the deadlines with a virtual clock instead of real waiting.
public struct AuthTimeouts: Sendable, Equatable {
    /// Deadline for flows that include interactive system auth UI
    /// (`ASAuthorizationController` / `ASWebAuthenticationSession`). Generous,
    /// because the user may legitimately be typing a password or completing
    /// 2FA inside the sheet; it exists to terminate the "callback never fires"
    /// hang, not to rush the user. The sign-in UI offers a cancel affordance
    /// for bailing out earlier.
    public var interactiveFlow: Duration
    /// Deadline for non-interactive backend calls (magic-link send/verify,
    /// credential sign-in, user fetch, session validation, team list, the
    /// post-sign-in hook). Sized above the Stack SDK's 30s per-request timeout
    /// so it only fires when retries stack up or a call wedges.
    public var network: Duration

    /// The production defaults: 300s interactive, 60s network.
    public static let `default` = AuthTimeouts(
        interactiveFlow: .seconds(300),
        network: .seconds(60)
    )

    /// Creates a timeout table.
    /// - Parameters:
    ///   - interactiveFlow: Deadline for flows with interactive system UI.
    ///   - network: Deadline for non-interactive backend calls.
    public init(interactiveFlow: Duration, network: Duration) {
        self.interactiveFlow = interactiveFlow
        self.network = network
    }
}
