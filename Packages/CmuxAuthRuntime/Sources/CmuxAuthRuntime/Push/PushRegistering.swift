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

    /// Remove the cached token from the server (on disable, while still
    /// signed in), authenticating through the live token provider.
    func unregisterFromServer() async

    /// Remove the cached token from the server on the sign-out path,
    /// authenticating with the credentials captured before the local-first
    /// sign-out cleared the live token provider. Passing `nil` for either
    /// token falls back to the provider.
    func unregisterFromServer(accessToken: String?, refreshToken: String?) async
}
