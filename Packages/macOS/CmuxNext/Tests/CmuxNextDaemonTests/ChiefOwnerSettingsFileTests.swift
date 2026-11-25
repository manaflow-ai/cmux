import Foundation
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

    /// The owner gets the absolute path the app's terminals get, not the raw value: a leading `~`
    /// is the home.
    @Test func theChiefOwnerGetsTheNormalizedPath() {
        let environment = DaemonLauncher.chiefEnvironment(["HOME": "/h", "CMUX_NEXT_CONFIG_FILE": "~/.config/cmux/x.json"])
        #expect(environment["CMUX_NEXT_CONFIG_FILE"] == "/h/.config/cmux/x.json")
    }

    /// The build's egress mode reaches the Chief owner and the link, so they enforce what the app does.
    @Test func theEgressModeReachesTheChiefOwnerAndTheLink() {
        #expect(DaemonLauncher.chiefEnvironment(["HOME": "/h", "CMUX_EGRESS": "enforce"])["CMUX_EGRESS"] == "enforce")
        #expect(DaemonLauncher.chiefEnvironment(["HOME": "/h", "CMUX_EGRESS": "log"])["CMUX_EGRESS"] == "log")
        let link = CloudLinkLauncher(binary: URL(fileURLWithPath: "/bin/cmux"), stateRoot: nil, tagged: true)
        #expect(link.environment(["HOME": "/h", "CMUX_EGRESS": "enforce"])["CMUX_EGRESS"] == "enforce")
    }
}
