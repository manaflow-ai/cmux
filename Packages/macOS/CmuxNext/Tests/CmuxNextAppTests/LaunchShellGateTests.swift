@testable import CmuxNextApp
import Testing

/// Stage 0 runs in a bench's no-activate launch only when the bench asks (`CMUX_NEXT_LAUNCH_SHELL=1`), so the
/// nightly warm launches can time the saved image while agent launches still open no stage-0 window.
struct LaunchShellGateTests {
    private let ask = [AppEnvironment.launchShellKey: "1"]

    @Test func aPersonsLaunchShowsStageZero() {
        #expect(AppEnvironment.showsLaunchShell(noActivate: false, testWindow: false, relaunchBehind: false, environment: [:]))
    }

    @Test func anAgentLaunchShowsNoneUnlessABenchAsks() {
        #expect(!AppEnvironment.showsLaunchShell(noActivate: true, testWindow: false, relaunchBehind: false, environment: [:]))
        #expect(!AppEnvironment.showsLaunchShell(noActivate: true, testWindow: false, relaunchBehind: false,
                                                 environment: [AppEnvironment.launchShellKey: "0"]))
        #expect(AppEnvironment.showsLaunchShell(noActivate: true, testWindow: false, relaunchBehind: false, environment: ask))
    }

    @Test func aTestWindowOrARelaunchBehindShowsNoneEvenWhenAsked() {
        #expect(!AppEnvironment.showsLaunchShell(noActivate: true, testWindow: true, relaunchBehind: false, environment: ask))
        #expect(!AppEnvironment.showsLaunchShell(noActivate: false, testWindow: false, relaunchBehind: true, environment: ask))
    }
}
