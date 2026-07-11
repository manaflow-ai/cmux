@testable import CmuxAndroidEmulator
import Testing

@Suite
struct AndroidEmulatorProcessLauncherTests {
    @Test
    func launchesWithHiddenWindowAndAuthenticatedDerivedGRPCPort() {
        #expect(AndroidEmulatorProcessLauncher.launchArguments(
            avdName: "pixel_api_36",
            consolePort: 5554
        ) == [
            "-avd", "pixel_api_36",
            "-port", "5554",
            "-qt-hide-window",
            "-grpc", "8554",
            "-grpc-use-token",
        ])
    }
}
