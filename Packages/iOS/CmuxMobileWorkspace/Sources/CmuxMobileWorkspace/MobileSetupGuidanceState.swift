/// The pre-pairing setup dead-end this device is currently in.
///
/// Before a phone can show a Mac's terminals it must clear four gates, in order:
/// be signed in, have the Mac app installed and running, be on a network path
/// that reaches the Mac (Tailscale, or the same LAN), and be signed in to the
/// *same* cmux account as the Mac. Each gate that is not yet cleared is its own
/// dead-end, and historically several of them looked identical (a blank
/// add-device screen) or failed silently. This enum names each one so the setup
/// help screen can show the one concrete next step that unblocks it.
///
/// This is *guidance* state, derived from durable, locally known signals (am I
/// signed in, have I ever paired, did the last connect fail on an account
/// mismatch). It is intentionally separate from the live connection state
/// machine: it never drives a connect attempt and never inspects an in-flight
/// pairing, so reading it cannot perturb pairing. Classified by
/// ``MobileSetupGuidancePolicy``.
public enum MobileSetupGuidanceState: Hashable, Sendable, CaseIterable {
    /// Fresh install, no Stack session on this device. The next step is to sign
    /// in with the same cmux account the Mac uses.
    case notSignedIn

    /// Signed in, but this device has never paired a Mac and none is reachable.
    /// The next step is to get the cmux Mac app installed and running, then pair.
    case signedInNeverPaired

    /// A Mac was paired before but is not reachable right now (the Mac app is
    /// quit, asleep, or off the shared network). The next step is to wake the Mac
    /// and confirm the network link, then reconnect.
    case macUnreachable

    /// The last pairing attempt was refused because this device is signed in to a
    /// different cmux account than the Mac. The next step is to sign this device
    /// in to the Mac's account (or sign the Mac in to this one).
    case accountMismatch
}
