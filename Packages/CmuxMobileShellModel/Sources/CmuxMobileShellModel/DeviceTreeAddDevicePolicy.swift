import Foundation

/// Pure policy for the device tree's "Add device" entry point, which re-enters
/// the pairing flow while a live connection may already exist (unlike the
/// first-run flow, which only ever runs disconnected).
///
/// Lives in the model package (with ``MobileConnectionState``) so it stays
/// platform-neutral and `swift test` exercises it on any host, following the
/// `MobileShellRouteAuthPolicy` pattern.
public enum DeviceTreeAddDevicePolicy {
    /// Whether tapping Cancel in the add-device sheet may reset the store's
    /// pairing state via `cancelPairing()`.
    ///
    /// `cancelPairing()` sets `connectionState = .disconnected` and clears the
    /// remote connection context. That is correct when the sheet was the only
    /// path to a connection (first-run, or an attempt that is mid-flight and
    /// already replaced the live client), but cancelling a freshly opened
    /// sheet while the shell is still connected must NOT tear down the live
    /// connection the user is actively using.
    public static func cancelResetsPairingState(connectionState: MobileConnectionState) -> Bool {
        connectionState != .connected
    }

    /// Whether the add-device sheet should dismiss after a pairing attempt
    /// completes. Success leaves the shell connected (to the newly added
    /// device); failure leaves it disconnected with `connectionError` set, and
    /// the sheet stays up so the user can read the error and retry.
    public static func dismissesAfterPairingAttempt(connectionState: MobileConnectionState) -> Bool {
        connectionState == .connected
    }
}
