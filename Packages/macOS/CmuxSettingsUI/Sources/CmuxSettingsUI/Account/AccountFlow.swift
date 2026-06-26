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
public protocol AccountFlow: AnyObject {
    /// The currently signed-in user, or `nil` if signed out.
    var currentIdentity: AccountIdentity? { get }

    /// Teams the current user belongs to. Empty when the user is
    /// signed out or the host hasn't loaded them yet.
    var availableTeams: [AccountTeamSummary] { get }

    /// Identifier of the currently selected team, or `nil` if none.
    var selectedTeamID: String? { get set }

    /// Whether the host is currently in the middle of a sign-in or
    /// sign-out network round trip. The UI disables interaction while
    /// this is `true`.
    var isWorkingOnAuth: Bool { get }

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
}
