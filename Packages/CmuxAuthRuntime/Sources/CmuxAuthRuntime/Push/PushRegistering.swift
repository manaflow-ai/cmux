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

    /// The set of workspace ids the currently signed-in user has muted for phone
    /// push. Push for a muted workspace is dropped server-side so a noisy
    /// workspace never reaches the phone, even while it is backgrounded or
    /// locked. The cache is namespaced by user id, so this always reflects the
    /// active account.
    var mutedWorkspaceIDs: Set<String> { get async }

    /// Mute or unmute a workspace for phone push for the signed-in user,
    /// persisting under that user's namespaced key and syncing the full muted set
    /// to the cmux web API. Because the persisted key is per-user, a write started
    /// under one account never lands in another account's cache. Concurrent
    /// toggles are coalesced into a single in-flight PUT.
    func setWorkspaceMuted(_ workspaceId: String, muted: Bool) async

    /// Pull the authoritative muted set from the server and replace the signed-in
    /// user's namespaced cache with it (call on sign-in). No-op (keeps local)
    /// when signed out or on a network failure, so an offline sign-in never wipes
    /// a valid local set, and a stale local mutation for the same user is not
    /// clobbered.
    /// - Returns: the muted set after hydration (server set on success, the
    ///   unchanged local set otherwise).
    @discardableResult
    func hydrateMutedWorkspacesFromServer() async -> Set<String>
}
