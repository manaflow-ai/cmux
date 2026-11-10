import CmuxNextDevices
@testable import CmuxNextMacScreen
import Testing

/// ui-state-fixes M5: Your Devices said "None of your other devices share Mac Screen" while the hub
/// had not started (`idle`) and "Loading your devices…" forever when it failed. An empty list is
/// "none shared" only once the hub is registered and the list was read; before that it is
/// loading; a failure is an error with Try Again.
@MainActor @Suite struct MacScreenDevicesLoadStateTests {
    let noneShared = L.t("macScreen.home.noSharedDevices", "None of your other devices share Mac Screen. On the Mac you want to see, turn on Allow Mac Screen on this Mac.")
    let loading = L.t("macScreen.home.devicesLoading", "Loading your devices…")

    @Test func anIdleOrStartingHubIsLoading() {
        for status in [DeviceHub.Status.idle, .starting] {
            let shown = MacScreenHomeSnapshot.noDevicesShown(status: status, listed: false, listFailed: false)
            #expect(shown == .note(loading), "\(status) said no device shares Mac Screen")
        }
    }

    @Test func aReadyHubIsLoadingUntilItsListIsRead() {
        #expect(MacScreenHomeSnapshot.noDevicesShown(status: .ready, listed: false, listFailed: false) == .note(loading))
        #expect(MacScreenHomeSnapshot.noDevicesShown(status: .ready, listed: true, listFailed: false) == .note(noneShared))
    }

    @Test func aFailureIsAnErrorWithRetryNotLoading() {
        let failed = MacScreenHomeSnapshot.noDevicesShown(status: .failed("offline"), listed: false, listFailed: false)
        guard case .failed = failed else {
            Issue.record("a failed hub showed \(failed)")
            return
        }
        let unread = MacScreenHomeSnapshot.noDevicesShown(status: .ready, listed: false, listFailed: true)
        guard case .failed = unread else {
            Issue.record("a failed list read showed \(unread)")
            return
        }
    }
}
