import CmuxMobileShellModel
import Testing

/// Behavior of the device tree's "Add device" entry point, which re-enters the
/// pairing flow while a live connection may already exist.
@Suite struct DeviceTreeAddDevicePolicyTests {
    private let policy = DeviceTreeAddDevicePolicy()

    /// Cancelling a sheet opened over a live connection must NOT call
    /// `cancelPairing()` — that would flip the store to `.disconnected` and
    /// tear down the connection the user is actively using.
    @Test func cancelOverLiveConnectionPreservesIt() {
        #expect(!policy.cancelResetsPairingState(connectionState: .connected))
    }

    /// Cancelling while disconnected (the attempt failed, or it already
    /// replaced the live client mid-flight) resets pairing state, matching the
    /// first-run flow's cancel semantics.
    @Test func cancelWhileDisconnectedResetsPairingState() {
        #expect(policy.cancelResetsPairingState(connectionState: .disconnected))
    }

    /// A successful attempt leaves the shell connected to the added device, so
    /// the sheet dismisses (and the tree refreshes to show it).
    @Test func successfulAttemptDismissesSheet() {
        #expect(policy.dismissesAfterPairingAttempt(connectionState: .connected))
    }

    /// A failed attempt leaves the shell disconnected with `connectionError`
    /// set; the sheet stays up so the user can read the error and retry.
    @Test func failedAttemptKeepsSheetForRetry() {
        #expect(!policy.dismissesAfterPairingAttempt(connectionState: .disconnected))
    }

    /// A failed or cancelled attempt that started over a live connection
    /// reconnects that Mac: the pairing path is destructive, and the user must
    /// not lose a working session to a bad QR code or a cancelled attempt.
    @Test func failedAttemptOverLiveConnectionRestoresIt() {
        #expect(policy.restoresPreviousConnection(
            connectionState: .disconnected,
            previousMacDeviceID: "mac-1"
        ))
    }

    /// A successful attempt is connected to the newly added device; the
    /// previous Mac must not be reconnected over it.
    @Test func successfulAttemptDoesNotRestorePreviousMac() {
        #expect(!policy.restoresPreviousConnection(
            connectionState: .connected,
            previousMacDeviceID: "mac-1"
        ))
    }

    /// An attempt that started without a live connection (first pair from the
    /// tree's empty state) has nothing to restore.
    @Test func failedAttemptWithNoPreviousMacDoesNotRestore() {
        #expect(!policy.restoresPreviousConnection(
            connectionState: .disconnected,
            previousMacDeviceID: nil
        ))
    }
}
