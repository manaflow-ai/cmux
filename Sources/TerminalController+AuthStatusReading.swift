import CmuxControlSocket
import Foundation

/// App-side wiring for the worker-lane `auth.*` control commands.
///
/// The command bodies live in CmuxControlSocket's ``ControlAuthWorker``; this
/// file supplies the live-state seam (``AuthStatusReading``) the worker reads
/// through, plus the one worker-thread→async bridge that lets the synchronous
/// `nonisolated` socket-worker lane drive the `async` worker.
///
/// ## Why the seam, not a direct call
///
/// `ControlAuthWorker` is in a package that cannot import the app target, and
/// the auth state it needs (`authCoordinator` / `browserSignInFlow`) is
/// main-actor state on `TerminalController`. `AuthStatusReading` inverts that:
/// the package owns the protocol, ``TerminalControllerAuthReading`` conforms it
/// over a `weak` `TerminalController`, hopping to the main actor inside each
/// member. This replaces the legacy per-command `DispatchSemaphore` +
/// `Task { @MainActor }` / `v2MainSync` bridges with the seam's `async` surface
/// (a deliberate isolation delta; see ``AuthStatusReading``).

extension TerminalController {
    /// Drives the package ``ControlAuthWorker`` for one decoded `auth.*` request
    /// from the synchronous socket-worker lane, blocking the worker thread until
    /// the async worker completes. This single semaphore is the one remaining
    /// worker-thread→async bridge (the legacy code blocked per command on its
    /// own semaphore / `DispatchQueue.main.sync`). The worker only ever returns
    /// `nil` for non-`auth.*` methods, which the dispatcher never routes here, so
    /// a `nil` result reports the same encode-failure response the legacy
    /// `v2Ok`/`v2Error` plumbing produced for an impossible payload.
    nonisolated func runAuthWorker(_ request: ControlRequest) -> String {
        guard let worker = controlAuthWorker else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ControlCallResult?
        Task {
            result = await worker.handle(request)
            semaphore.signal()
        }
        semaphore.wait()
        guard let result else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }

    /// Builds the typed auth snapshot off the live coordinator, or `nil` when no
    /// coordinator is wired (the legacy "not signed in" fallback). Byte-faithful
    /// to the former `v2AuthStatusPayload` field mapping (minus `timed_out`,
    /// which the worker folds in per command).
    func controlAuthStatusSnapshot() -> ControlAuthStatus? {
        guard let coordinator = authCoordinator else { return nil }
        let isSigningIn = browserSignInFlow?.isSigningIn ?? false
        let user = coordinator.currentUser.map { user in
            ControlAuthUser(
                id: user.id,
                email: user.primaryEmail,
                displayName: user.displayName
            )
        }
        let teams = coordinator.availableTeams.map { team in
            ControlAuthTeam(
                id: team.id,
                displayName: team.displayName,
                slug: team.slug
            )
        }
        return ControlAuthStatus(
            signedIn: coordinator.isAuthenticated,
            isRestoringSession: coordinator.isRestoringSession,
            isLoading: coordinator.isLoading || isSigningIn,
            user: user,
            selectedTeamID: coordinator.resolvedTeamID,
            teams: teams
        )
    }

    /// Awaits any in-flight launch bootstrap on the auth coordinator (matches
    /// `auth.status`'s former `await self?.authCoordinator?.awaitBootstrapped()`).
    func controlAuthAwaitBootstrapped() async {
        await authCoordinator?.awaitBootstrapped()
    }

    /// The manual sign-in URL string the browser flow would open, or `nil`.
    func controlAuthSignInURL() -> String? {
        browserSignInFlow?.manualSignInURL.absoluteString
    }

    /// Drives an interactive browser sign-in, returning whether it succeeded.
    func controlAuthBeginSignIn(timeoutSeconds: TimeInterval) async -> Bool {
        await browserSignInFlow?.signIn(timeout: timeoutSeconds) ?? false
    }

    /// Signs out via the browser flow with the legacy fixed 5-second teardown.
    func controlAuthSignOut() async {
        await browserSignInFlow?.signOut(timeout: 5)
    }
}

/// Conforms ``AuthStatusReading`` over a `weak` ``TerminalController``. The
/// members read the controller's main-actor auth state, so the conformer is
/// `@MainActor` (which makes it `Sendable`, satisfying the seam): each `async`
/// member runs on the main actor when awaited, and `ControlAuthWorker` carries
/// the conformer across the worker-thread boundary safely because a `@MainActor`
/// reference type is `Sendable`. This is the inverse of the legacy bridge,
/// which hopped onto the main actor per command from the worker thread.
@MainActor
final class TerminalControllerAuthReading: AuthStatusReading {
    private weak var owner: TerminalController?

    init(owner: TerminalController) {
        self.owner = owner
    }

    func awaitBootstrapped() async {
        await owner?.controlAuthAwaitBootstrapped()
    }

    func statusSnapshot() async -> ControlAuthStatus? {
        owner?.controlAuthStatusSnapshot() ?? nil
    }

    func signInURL() async -> String? {
        owner?.controlAuthSignInURL() ?? nil
    }

    func beginSignIn(timeoutSeconds: TimeInterval) async -> Bool {
        await owner?.controlAuthBeginSignIn(timeoutSeconds: timeoutSeconds) ?? false
    }

    func signOut() async {
        await owner?.controlAuthSignOut()
    }
}
