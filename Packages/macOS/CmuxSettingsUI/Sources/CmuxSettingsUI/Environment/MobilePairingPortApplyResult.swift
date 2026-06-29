import Foundation

/// The result of an explicit "Apply" of the iOS pairing port from the Mobile
/// settings section.
///
/// The Mobile section uses this to render inline feedback. The host checks
/// whether the port can be bound *before* disturbing a running listener, so a
/// conflict leaves existing connections intact (``portInUse``).
public enum MobilePairingPortApplyResult: Sendable, Equatable {
    /// The port was accepted; the listener is (or will be) bound to it.
    case applied(port: Int)

    /// The port is in use by another process; the running listener was left
    /// untouched (still on its current port).
    case portInUse(requestedPort: Int)

    /// Pairing is off, so the port was saved and will bind when pairing is on.
    case savedForLater(port: Int)

    /// The requested port was outside the valid `1...65535` range.
    case invalid(requestedPort: Int)
}
