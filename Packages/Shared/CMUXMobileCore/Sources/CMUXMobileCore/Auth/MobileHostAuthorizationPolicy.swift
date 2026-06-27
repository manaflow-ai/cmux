import Foundation

/// Same-account authorization check binding a remote Stack user ID to the Mac
/// owner's locally signed-in Stack user ID.
///
/// Pure string comparison: both IDs are trimmed of surrounding whitespace and an
/// empty result is treated as absent. Holds no state, so any instance behaves
/// identically.
public struct MobileHostAuthorizationPolicy: Sendable {
    public init() {}

    /// Throws `MobileHostAuthorizationError.missingLocalUser` when no user is
    /// signed in on this Mac, and `.accountMismatch` when `remoteUserID` does not
    /// resolve to the same non-empty Stack user ID as `localUserID`.
    public func authorizeStackUserID(localUserID: String?, remoteUserID: String?) throws {
        guard let localUserID = Self.normalizedUserID(localUserID) else {
            throw MobileHostAuthorizationError.missingLocalUser
        }
        guard Self.normalizedUserID(remoteUserID) == localUserID else {
            throw MobileHostAuthorizationError.accountMismatch
        }
    }

    /// Whether a mobile data-plane RPC method must be authorized before it runs.
    ///
    /// Every method requires authorization except the unauthenticated host probe.
    public func requiresAuthorization(method: String) -> Bool {
        switch method {
        // Only the unauthenticated host probe is exempt. `mobile.attach_ticket.create`
        // mints a bearer credential, so it MUST be authorized: a network caller has no
        // attach token yet, so it is routed through the same-account Stack Auth token
        // (the iOS client always sends it for this method). Leaving it exempt would let
        // any process that can speak the wire protocol self-issue a working ticket and
        // take over the terminal. The on-Mac QR pairing mints tickets through the local
        // automation socket (`TerminalController`), not this network path, so it is
        // unaffected.
        case "mobile.host.status":
            return false
        default:
            return true
        }
    }

    private static func normalizedUserID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
