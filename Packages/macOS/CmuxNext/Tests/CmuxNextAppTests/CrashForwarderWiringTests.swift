@testable import CmuxNextApp
import CmuxNextWakeups
import Foundation
import Testing

/// The app's wiring of the crash forwarder: the hang-reports controller decides whether a
/// Rust crash's black box may go (``CmuxNextCrashReporting/RustBlackBoxConsent``), and the forwarder looks for host
/// and holder copies where the app's daemon puts them.
@MainActor @Suite struct CrashForwarderWiringTests {
    /// The decisions the controller told.
    @MainActor final class Decisions {
        var values: [Bool] = []
    }

    /// A channel that never sends (Release, RC, DEV without the opt-in) has no service: it decides off at once, so
    /// a leftover consent record never counts there and the forwarder starts.
    @Test func aBuildThatNeverSendsDecidesOffAtOnce() {
        let decisions = Decisions()
        _ = HangReportsController(service: nil, managedDisables: { false }, work: BackgroundWork(label: "test.blackbox-consent"),
                                  mainWork: MainWorkScheduler(budget: MainFrameBudget()), blackboxConsent: { decisions.values.append($0) })
        #expect(decisions.values == [false])
    }

    /// The app's launch strips its own `CMUX_TUI_HOST_EXE_DIR`; the daemon gets the root from the app's
    /// `CMUX_NEXT_TUI_HOST_EXE_DIR` knob, and the forwarder reads the same one.
    @Test func theForwardersHostExeRootIsTheDaemons() {
        let home = URL(filePath: "/Users/alice", directoryHint: .isDirectory)
        let standard = "/Users/alice/Library/Application Support/cmux-tui/host-exe"
        #expect(AppCrashReporting.hostExeRoot(environment: [:], home: home) == standard)
        #expect(AppCrashReporting.hostExeRoot(environment: ["CMUX_NEXT_TUI_HOST_EXE_DIR": "/tmp/hx"], home: home) == "/tmp/hx")
        #expect(AppCrashReporting.hostExeRoot(environment: ["CMUX_TUI_HOST_EXE_DIR": "/tmp/stale"], home: home) == standard,
                "the daemon's own name never reaches the daemon from the app")
    }
}
