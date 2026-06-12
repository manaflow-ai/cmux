import Foundation

/// Pure policy for the device tree's "Add device" entry point, which re-enters
/// the pairing flow while a live connection may already exist (unlike the
/// first-run flow, which only ever runs disconnected).
///
/// Lives in the model package (with ``MobileConnectionState``) so it stays
/// platform-neutral and `swift test` exercises it on any host, following the
/// `MobileShellRouteAuthPolicy` pattern. A value type (not a static-helper
/// namespace) per the package API design policy.
public struct DeviceTreeAddDevicePolicy: Sendable {
    public init() {}

    /// Whether tapping Cancel in the add-device sheet may reset the store's
    /// pairing state via `cancelPairing()`.
    ///
    /// `cancelPairing()` sets `connectionState = .disconnected` and clears the
    /// remote connection context. That is correct when the sheet was the only
    /// path to a connection (first-run, or an attempt that is mid-flight and
    /// already replaced the live client), but cancelling a freshly opened
    /// sheet while the shell is still connected must NOT tear down the live
    /// connection the user is actively using.
    public func cancelResetsPairingState(connectionState: MobileConnectionState) -> Bool {
        connectionState != .connected
    }

    /// Whether the add-device sheet should dismiss after a pairing attempt
    /// completes. Success leaves the shell connected (to the newly added
    /// device); failure leaves it disconnected with `connectionError` set, and
    /// the sheet stays up so the user can read the error and retry.
    public func dismissesAfterPairingAttempt(connectionState: MobileConnectionState) -> Bool {
        connectionState == .connected
    }

    /// Whether a completed add-device attempt should reconnect the Mac that
    /// was live when the attempt started.
    ///
    /// The underlying pairing path is destructive: a failed (or cancelled)
    /// attempt leaves the shell `.disconnected` even when a healthy connection
    /// existed before it began. When the attempt started over a live
    /// connection (`previousMacDeviceID` non-nil) and ended disconnected,
    /// restore that Mac via `switchToMac` instead of stranding the user —
    /// the same "never strand the user" contract `switchToMac` documents for
    /// its own failure path. A successful attempt is connected (to the new
    /// device), so no restore happens.
    public func restoresPreviousConnection(
        connectionState: MobileConnectionState,
        previousMacDeviceID: String?
    ) -> Bool {
        connectionState != .connected && previousMacDeviceID != nil
    }
}
