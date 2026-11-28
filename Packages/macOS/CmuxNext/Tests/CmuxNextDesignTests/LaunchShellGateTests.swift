import CmuxNextDesign
import Testing

/// Stage 0 runs in a bench's no-activate launch only when the bench asks (`CMUX_NEXT_LAUNCH_SHELL=1`), so the
/// nightly warm launches can time the saved image while agent launches still open no stage-0 window.
struct LaunchShellGateTests {
    private let ask = [LaunchShell.benchKey: "1"]

    @Test func aPersonsLaunchShowsStageZero() {
        #expect(LaunchShell.shows(noActivate: false, testWindow: false, relaunchBehind: false, environment: [:]))
    }

    @Test func anAgentLaunchShowsNoneUnlessABenchAsks() {
        #expect(!LaunchShell.shows(noActivate: true, testWindow: false, relaunchBehind: false, environment: [:]))
        #expect(!LaunchShell.shows(noActivate: true, testWindow: false, relaunchBehind: false, environment: [LaunchShell.benchKey: "0"]))
        #expect(LaunchShell.shows(noActivate: true, testWindow: false, relaunchBehind: false, environment: ask))
    }

    @Test func aTestWindowOrARelaunchBehindShowsNoneEvenWhenAsked() {
        #expect(!LaunchShell.shows(noActivate: true, testWindow: true, relaunchBehind: false, environment: ask))
        #expect(!LaunchShell.shows(noActivate: false, testWindow: false, relaunchBehind: true, environment: ask))
    }
}
