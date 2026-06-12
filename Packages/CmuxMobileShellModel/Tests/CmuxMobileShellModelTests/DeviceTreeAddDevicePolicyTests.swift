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

    /// A cancelled attempt (disconnected, no connection error — the store's
    /// cancellation path sets none) that started over a live connection
    /// reconnects that Mac: the pairing path is destructive, and the user must
    /// not lose a working session just by backing out of the sheet.
    @Test func cancelledAttemptOverLiveConnectionRestoresIt() {
        #expect(policy.restoresPreviousConnection(
            connectionState: .disconnected,
            previousMacDeviceID: "mac-1",
            hasConnectionError: false
        ))
    }

    /// A failed attempt (connection error set) must NOT auto-restore: the
    /// reconnect path begins a fresh pairing attempt, which clears
    /// `connectionError` and would erase the failure reason while the user is
    /// reading it on the auto-presented pairing sheet.
    @Test func failedAttemptKeepsErrorInsteadOfRestoring() {
        #expect(!policy.restoresPreviousConnection(
            connectionState: .disconnected,
            previousMacDeviceID: "mac-1",
            hasConnectionError: true
        ))
    }

    /// A successful attempt is connected to the newly added device; the
    /// previous Mac must not be reconnected over it.
    @Test func successfulAttemptDoesNotRestorePreviousMac() {
        #expect(!policy.restoresPreviousConnection(
            connectionState: .connected,
            previousMacDeviceID: "mac-1",
            hasConnectionError: false
        ))
    }

    /// An attempt that started without a live connection (first pair from the
    /// tree's empty state) has nothing to restore.
    @Test func cancelledAttemptWithNoPreviousMacDoesNotRestore() {
        #expect(!policy.restoresPreviousConnection(
            connectionState: .disconnected,
            previousMacDeviceID: nil,
            hasConnectionError: false
        ))
    }
}
