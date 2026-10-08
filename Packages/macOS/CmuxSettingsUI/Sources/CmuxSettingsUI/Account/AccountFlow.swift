import Foundation

/// Host-supplied dependency the package's ``AccountSection`` uses to
/// render and drive the sign-in / sign-out flow.
///
/// The package deliberately does not link the host app's auth library
/// (`CMUXAuthCore`) so it stays buildable in isolation. The host wraps
/// its own auth surface in an `AccountFlow` implementation and injects
/// it via ``SettingsRuntime/init(catalog:userDefaultsStore:jsonStore:errorLog:accountFlow:)``.
///
/// Implementations must be `@MainActor`-safe because the package reads
/// `currentIdentity` / `availableTeams` / `selectedTeamID` from view
/// bodies. Use `@Observable` so SwiftUI tracks changes.
@MainActor
public protocol AccountFlow: AccountTeamManagement {
    /// The currently signed-in user, or `nil` if signed out.
    var currentIdentity: AccountIdentity? { get }

    /// Teams the current user belongs to. Empty when the user is
    /// signed out or the host hasn't loaded them yet.
    var availableTeams: [AccountTeamSummary] { get }

    /// Identifier of the currently selected team, or `nil` if none.
    var selectedTeamID: String? { get }

    /// Team confirmed by the auth service and used for billing requests.
    /// Unlike the picker selection, this excludes an in-flight optimistic choice.
    var confirmedTeamID: String? { get }

    /// Selects a team through the host's shared auth mutation path.
    /// - Parameter id: A member team id, or `nil` to clear the explicit choice.
    func selectTeam(id: String?) async throws

    /// Whether the host is currently in the middle of a sign-in or
    /// sign-out network round trip. The UI disables interaction while
    /// this is `true`.
    var isWorkingOnAuth: Bool { get }

    /// Whether the host has completed authentication for the current account.
    var isAuthenticated: Bool { get }

    /// Whether an in-flight sign-in has been waiting on the system sign-in
    /// window long enough to offer a fallback. On macOS that window is always
    /// Safari-backed and can hang without ever redirecting back, so the UI
    /// surfaces an "open in your default browser" affordance instead of an
    /// indefinite spinner when this is `true`.
    var signInIsSlow: Bool { get }

    /// Launches the host's sign-in flow. The package shows the user a
    /// progress indicator while ``isWorkingOnAuth`` is `true` and
    /// re-reads ``currentIdentity`` when the flow resolves.
    func startSignIn()

    /// Opens the in-flight sign-in in the user's default browser as a fallback
    /// when the system sign-in window hangs (``signInIsSlow``). The browser
    /// completes the sign-in and deep-links back into the app to finish the
    /// in-flight attempt. A no-op when no sign-in is in flight.
    func openSignInInDefaultBrowser()

    /// Signs out and clears any cached identity. After this returns,
    /// ``currentIdentity`` reads as `nil`.
    func signOut() async

    /// Re-fetches the current user from the backend, refreshing the
    /// identity card without forcing the user through sign-in again.
    func refreshCurrentUser() async

    /// Opens the cmux Pro upgrade (pricing) page in the user's default
    /// browser. The host decides the destination URL so dev builds can
    /// point at a local web server.
    func openProUpgrade()

    /// Hover hint that ``openProUpgrade()`` is likely next: the host can
    /// start loading the pricing destination so the click opens instantly.
    /// Must be safe to call repeatedly. Defaults to a no-op.
    func prefetchProUpgrade()

    /// Re-fetches the billing plan state used by the Pro account row.
    func refreshBillingPlan() async

    /// Opens the hosted Stripe customer portal in the user's default browser.
    func openBillingPortal()

    /// Whether the Pro upgrade row should render. The host backs this with
    /// a remotely toggleable feature flag; `true` when flags are
    /// unavailable only in explicit dogfood builds whose flag default is on.
    var isProUpgradeAvailable: Bool { get }

    /// Whether the current account has an active Pro entitlement.
    var isProActive: Bool { get }

    /// Whether ``isProActive`` has been resolved for the current account.
    ///
    /// A host may briefly know the signed-in identity from its local session
    /// cache while its auth tokens are still being restored. Settings should
    /// keep the plan action in a loading state during that gap instead of
    /// presenting a false upgrade prompt.
    var isProStatusKnown: Bool { get }

    /// Whether the current Pro entitlement can be managed through the hosted
    /// Stripe billing portal.
    var canManageBilling: Bool { get }
}

extension AccountFlow {
    /// Hosts without optimistic team selection use their selected team directly.
    public var confirmedTeamID: String? { selectedTeamID }

    public func prefetchProUpgrade() {}

    /// Package-only hosts can use the identity and auth activity as their
    /// authentication answer because they do not own a separate coordinator.
    public var isAuthenticated: Bool {
        currentIdentity != nil && !isWorkingOnAuth
    }

    /// Package-only hosts do not have a remote billing source, so their
    /// existing behavior remains the immediately available upgrade action.
    public var isProStatusKnown: Bool { true }
}
