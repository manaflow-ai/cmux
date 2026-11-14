import Testing
@testable import CmuxNextDaemon

/// The Chief owner reads the settings file the app writes: an app launched on its own file
/// (`CMUX_NEXT_CONFIG_FILE`, a tagged dogfood build) hands it to the owner's `server ensure`, as it
/// does to its own daemon, so the owner and its brains never read the shared cmux-next.json. Its
/// other cmux identity still stays out.
struct ChiefOwnerSettingsFileTests {
    @Test func theAppsOwnSettingsFileReachesTheChiefOwner() {
        let environment = DaemonLauncher.chiefEnvironment([
            "HOME": "/h", "CMUX_NEXT_CONFIG_FILE": "/h/.config/cmux/cmux-next-cu-fresh.json",
            "CMUX_TAG": "cu-fresh", "CMUX_SOCKET_PATH": "/tmp/s.sock",
        ])
        #expect(environment == ["HOME": "/h", "CMUX_NEXT_CONFIG_FILE": "/h/.config/cmux/cmux-next-cu-fresh.json"])
    }

    @Test func anAppOnTheSharedFileSetsNone() {
        #expect(DaemonLauncher.chiefEnvironment(["HOME": "/h"])["CMUX_NEXT_CONFIG_FILE"] == nil)
    }
}
