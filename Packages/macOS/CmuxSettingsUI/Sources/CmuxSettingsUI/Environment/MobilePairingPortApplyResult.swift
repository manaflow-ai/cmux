import Foundation

/// The result of an explicit "Apply" of the iOS pairing port from the Mobile
/// settings section.
///
/// The result drives inline feedback. The IROH owner saves a new preference
/// for its next start so changing this setting leaves current sessions intact.
public enum MobilePairingPortApplyResult: Sendable, Equatable {
    /// The port was accepted; the listener is (or will be) bound to it.
    case applied(port: Int)

    /// The port is in use by another process; the running listener was left
    /// untouched (still on its current port).
    case portInUse(requestedPort: Int)

    /// The port was saved for the next pairing start.
    case savedForLater(port: Int)

    /// The requested port was outside the valid `1...65535` range.
    case invalid(requestedPort: Int)
}
