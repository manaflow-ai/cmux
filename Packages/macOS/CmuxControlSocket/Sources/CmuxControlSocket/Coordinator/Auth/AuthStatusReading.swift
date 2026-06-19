public import Foundation

/// The read-only seam through which ``ControlAuthWorker`` reaches the live auth
/// coordinator (and the browser sign-in flow) to serve the worker-lane `auth.*`
/// control commands, without the package importing the app target.
///
/// ## Isolation delta (deliberate, documented)
///
/// The legacy `auth.*` bodies ran on the nonisolated socket-worker thread and
/// hopped onto the main actor with a `DispatchSemaphore` + `Task { @MainActor }`
/// (`auth.status`/`auth.begin_sign_in`/`auth.sign_out`) or `v2MainSync`
/// (`auth.sign_in_url`), blocking the worker thread until the main-actor work
/// signalled. This seam replaces every one of those bridges with an `async`
/// surface: each member awaits the coordinator on its own actor and returns a
/// `Sendable` value. The worker (``ControlAuthWorker``) is therefore `async`,
/// and the single remaining worker-thread→async bridge lives in the app's
/// worker-lane dispatcher, not per-command inside the bodies. The observable
/// behavior is preserved: `statusSnapshot()` still awaits bootstrap completion
/// before reading (the caller awaits ``awaitBootstrapped()`` first, matching
/// `auth.status`'s former `await coordinator.awaitBootstrapped()`), and the
/// payloads are byte-identical.
///
/// `Sendable` (not `@MainActor`) so the worker can hold it across the
/// worker-thread boundary; the app conformer hops to the main actor internally
/// to read `authCoordinator` / `browserSignInFlow`.
public protocol AuthStatusReading: Sendable {
    /// Awaits any in-flight launch bootstrap so a subsequent ``statusSnapshot()``
    /// reflects the settled session, matching the legacy `auth.status`
    /// `await self?.authCoordinator?.awaitBootstrapped()`. A no-op when no
    /// coordinator is present.
    func awaitBootstrapped() async

    /// The current auth status, or `nil` when no auth coordinator is wired
    /// (the legacy "not signed in" fallback). Reads `isAuthenticated` /
    /// `isRestoringSession` / `isLoading` / `currentUser` / `resolvedTeamID` /
    /// `availableTeams` off the coordinator and folds in the browser sign-in
    /// flow's `isSigningIn` flag, exactly as `v2AuthStatusPayload` did.
    func statusSnapshot() async -> ControlAuthStatus?

    /// The manual sign-in URL the browser flow would open, or `nil` when no
    /// browser sign-in flow is wired (matches `auth.sign_in_url`'s
    /// `browserSignInFlow?.manualSignInURL.absoluteString`).
    func signInURL() async -> String?

    /// Drives an interactive sign-in with the given timeout, returning whether
    /// it succeeded (matches `auth.begin_sign_in`'s
    /// `browserSignInFlow?.signIn(timeout:) ?? false`).
    ///
    /// - Parameter timeoutSeconds: The sign-in timeout in seconds.
    /// - Returns: `true` on success, `false` on timeout/failure or when no
    ///   browser sign-in flow is wired.
    func beginSignIn(timeoutSeconds: TimeInterval) async -> Bool

    /// Signs out, tearing down with a fixed 5-second timeout (matches
    /// `auth.sign_out`'s `browserSignInFlow?.signOut(timeout: 5)`). A no-op when
    /// no browser sign-in flow is wired.
    func signOut() async
}
