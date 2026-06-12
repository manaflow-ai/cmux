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
    /// Creates the policy. Stateless today; an initializer (rather than a
    /// static-helper namespace) keeps the public API injectable and free to
    /// grow configuration without breaking call sites.
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
    /// The underlying pairing path is destructive: a cancelled attempt leaves
    /// the shell `.disconnected` even when a healthy connection existed before
    /// it began. When the attempt started over a live connection
    /// (`previousMacDeviceID` non-nil), ended disconnected, and reported no
    /// connection error (the store's cancellation path sets none, while every
    /// real failure does), restore that Mac via `switchToMac` instead of
    /// stranding the user — the same "never strand the user" contract
    /// `switchToMac` documents for its own failure path.
    ///
    /// A failed attempt (`hasConnectionError`) deliberately does NOT restore:
    /// the reconnect path begins a fresh pairing attempt, which clears
    /// `connectionError` and would erase the actionable failure reason while
    /// the user is reading it. The disconnected shell auto-presents the
    /// pairing sheet with that error for an in-place retry; reconnecting the
    /// previous Mac without losing the error needs a store-owned error
    /// channel that survives reconnects (follow-up). A successful attempt is
    /// connected (to the new device), so no restore happens either.
    public func restoresPreviousConnection(
        connectionState: MobileConnectionState,
        previousMacDeviceID: String?,
        hasConnectionError: Bool
    ) -> Bool {
        connectionState != .connected && previousMacDeviceID != nil && !hasConnectionError
    }
}
