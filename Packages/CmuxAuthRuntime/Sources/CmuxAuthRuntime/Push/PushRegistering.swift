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
    /// the next ``syncMutedWorkspacesIfPossible()`` re-uploads.
    func setWorkspaceMuted(_ workspaceId: String, muted: Bool) async

    /// Re-upload the muted set when possible (e.g. after sign-in).
    func syncMutedWorkspacesIfPossible() async
}
