public import Foundation

/// The device-token registration seam the push coordinator drives.
///
/// Owns the opt-in flag and the device-token sync with the cmux web API.
/// ``PushRegistrationService`` is the production conformer. The seam keeps the
/// UIKit-bound coordinator (authorization + `registerForRemoteNotifications`)
/// separate from the Foundation-only network work, and lets tests substitute a
/// fake registrar.
public protocol PushRegistering: Sendable {
    /// Whether the user has opted into phone notifications.
    var isEnabled: Bool { get async }

    /// Persist the opt-in flag, re-uploading any cached token on enable and
    /// removing it server-side on disable.
    func setEnabled(_ enabled: Bool) async

    /// Cache and (when opted in) upload a freshly registered APNs device token.
    func register(deviceToken: Data) async

    /// Re-upload the cached token (e.g. after sign-in). No-op unless opted in.
    func syncTokenIfPossible() async

    /// Remove the cached token from the server (on disable or sign-out).
    func unregisterFromServer() async

    /// The set of workspace ids the user has muted for phone push. Push for a
    /// muted workspace is dropped server-side so a noisy workspace never reaches
    /// the phone, even while it is backgrounded or locked.
    var mutedWorkspaceIDs: Set<String> { get async }

    /// Mute or unmute a workspace for phone push, persisting locally and syncing
    /// the full muted set to the cmux web API. Persists even when not signed in;
    /// the next ``hydrateMutedWorkspacesFromServer()`` reconciles against the
    /// server set. Concurrent toggles are coalesced into a single in-flight PUT.
    func setWorkspaceMuted(_ workspaceId: String, muted: Bool) async

    /// Pull the authoritative muted set from the server and replace the local
    /// cache with it (call on sign-in). The server set is keyed by the
    /// authenticated user, so this is what scopes mutes per account: a different
    /// user signing in overwrites the previous user's locally cached set instead
    /// of re-uploading it. No-op (keeps local) when signed out or on a network
    /// failure, so an offline sign-in never wipes a valid local set.
    /// - Returns: the muted set after hydration (server set on success, the
    ///   unchanged local set otherwise).
    @discardableResult
    func hydrateMutedWorkspacesFromServer() async -> Set<String>

    /// Clear the locally cached muted set (call on sign-out) so the next user
    /// starts from their own server state, not the previous user's cache. Does
    /// not touch the server (the signed-out user's server rows are theirs to
    /// keep); it only prevents cross-account local leakage.
    func clearLocalMutedWorkspaces() async
}
