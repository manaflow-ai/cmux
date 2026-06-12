import CmuxMobileShellModel
import Testing

/// Behavior of the device tree's "Add device" entry point, which re-enters the
/// pairing flow while a live connection may already exist.
@Suite struct DeviceTreeAddDevicePolicyTests {
    /// Cancelling a sheet opened over a live connection must NOT call
    /// `cancelPairing()` — that would flip the store to `.disconnected` and
    /// tear down the connection the user is actively using.
    @Test func cancelOverLiveConnectionPreservesIt() {
        #expect(!DeviceTreeAddDevicePolicy.cancelResetsPairingState(connectionState: .connected))
    }

    /// Cancelling while disconnected (the attempt failed, or it already
    /// replaced the live client mid-flight) resets pairing state, matching the
    /// first-run flow's cancel semantics.
    @Test func cancelWhileDisconnectedResetsPairingState() {
        #expect(DeviceTreeAddDevicePolicy.cancelResetsPairingState(connectionState: .disconnected))
    }

    /// A successful attempt leaves the shell connected to the added device, so
    /// the sheet dismisses (and the tree refreshes to show it).
    @Test func successfulAttemptDismissesSheet() {
        #expect(DeviceTreeAddDevicePolicy.dismissesAfterPairingAttempt(connectionState: .connected))
    }

    /// A failed attempt leaves the shell disconnected with `connectionError`
    /// set; the sheet stays up so the user can read the error and retry.
    @Test func failedAttemptKeepsSheetForRetry() {
        #expect(!DeviceTreeAddDevicePolicy.dismissesAfterPairingAttempt(connectionState: .disconnected))
    }
}
