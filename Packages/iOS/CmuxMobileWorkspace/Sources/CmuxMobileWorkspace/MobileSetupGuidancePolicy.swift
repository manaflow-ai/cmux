/// Pure classifier mapping locally known setup signals to the
/// ``MobileSetupGuidanceState`` the setup help screen renders.
///
/// Kept as a pure function (no store, no UIKit, no connect side effects) so the
/// not-signed-in / never-paired / unreachable / account-mismatch decision is
/// unit-testable without standing up the shell, and so reading it can never
/// perturb the pairing client state machine. It mirrors ``MobileOnboardingGate``
/// and ``MobileRootAuthGate``.
///
/// This classifier is about *setup guidance the user can re-open from Settings*,
/// not the runtime disconnected screen. It deliberately overlaps with, but does
/// not replace, the connection-state classification used while the disconnected
/// screen is mounted: that one answers "why is the live link down right now",
/// while this one answers "which setup gate is the user stuck behind and what do
/// they do about it", which is also meaningful while signed out (where there is
/// no connection state at all).
public struct MobileSetupGuidancePolicy {
    private init() {}

    /// Classify the setup help screen's state from durable local signals.
    ///
    /// Precedence, most specific first:
    /// 1. A recorded account mismatch wins even when otherwise signed in, because
    ///    it is a definitive, actionable failure the user must resolve before any
    ///    other step matters.
    /// 2. Not signed in: nothing else can be attempted until there is a session.
    /// 3. A known paired Mac that is simply unreachable: guide to wake/reconnect.
    /// 4. Otherwise: signed in but never paired, guide to install the Mac app and
    ///    pair.
    ///
    /// - Parameters:
    ///   - isSignedIn: Whether this device has a Stack session.
    ///   - hasKnownPairedMac: Whether this install has ever paired a Mac.
    ///   - hasAccountMismatch: Whether the most recent pairing attempt was refused
    ///     because the device's account does not match the Mac's.
    /// - Returns: The single setup gate the user is currently behind.
    public static func state(
        isSignedIn: Bool,
        hasKnownPairedMac: Bool,
        hasAccountMismatch: Bool
    ) -> MobileSetupGuidanceState {
        if hasAccountMismatch {
            return .accountMismatch
        }
        if !isSignedIn {
            return .notSignedIn
        }
        if hasKnownPairedMac {
            return .macUnreachable
        }
        return .signedInNeverPaired
    }
}
