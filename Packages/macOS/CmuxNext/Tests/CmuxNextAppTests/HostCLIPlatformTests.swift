import CmuxNextRemote
import Foundation
import Testing

/// `HostCLI.onPlatform(of:)`: the app's platform runs (`machine list|add|doctor`, `device`) carry the launch's
/// `CMUX_PLATFORM_ORIGIN`, so a staging or development app lists its own joined machines, not production's.
struct HostCLIPlatformTests {
    let cli = HostCLI(binary: URL(fileURLWithPath: "/bin/true")) { ["HOME": "/h", "CMUX_PLATFORM_ORIGIN": "https://old.example"] }

    @Test func theLaunchOriginWins() async {
        let env = await cli.onPlatform(of: ["CMUX_PLATFORM_ORIGIN": "https://dev.example", "CMUX_TAG": "lane"]).environment()
        #expect(env == ["HOME": "/h", "CMUX_PLATFORM_ORIGIN": "https://dev.example"])
    }

    @Test func noLaunchOriginKeepsTheCLIsOwn() async {
        #expect(await cli.onPlatform(of: ["CMUX_TAG": "lane"]).environment() == ["HOME": "/h", "CMUX_PLATFORM_ORIGIN": "https://old.example"])
    }
}
