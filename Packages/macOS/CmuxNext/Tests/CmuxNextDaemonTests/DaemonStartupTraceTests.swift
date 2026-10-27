import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p08-startup-099: with `CMUX_TRACE_STARTUP` on, `server ensure` (the call that spawns a cold owner) hands the
/// daemon its startup trace file under the daemon's names until the app's trace deadline; after it, or without a
/// trace, it adds nothing.
struct DaemonStartupTraceTests {
    private static let second: UInt64 = 1_000_000_000
    private static let file = URL(fileURLWithPath: "/tmp/startup/startup-daemon.json")

    private func launcher(_ trace: DaemonStartupTrace?) -> DaemonLauncher {
        let configuration = DaemonLauncher.Configuration(binary: URL(fileURLWithPath: "/nonexistent/cmux-tui"), session: "cmux-app-trace",
                                                         runtimeBase: URL(fileURLWithPath: "/tmp", isDirectory: true),
                                                         startupTrace: trace)
        return DaemonLauncher(work: BackgroundWork(label: "test.daemon-startup-trace"), configuration: configuration,
                              environment: { ["HOME": "/home/me", DaemonStartupTrace.secondsKey: "99"] })
    }

    @Test func aTraceBeforeItsDeadlineReachesTheEnsureEnvironment() async {
        let environment = await launcher(DaemonStartupTrace(deadlineNanos: .max, file: Self.file)).ensureEnvironment()
        #expect(environment["CMUX_TUI_TRACE_STARTUP_FILE"] == "/tmp/startup/startup-daemon.json")
        #expect(environment["CMUX_TUI_TRACE_STARTUP"] != "99")
        #expect(environment["HOME"] == "/home/me")
    }

    /// A daemon a reconnect spawns after the app's trace closed never writes over the launch's file.
    @Test func aTracePastItsDeadlineAddsNothing() async {
        let environment = await launcher(DaemonStartupTrace(deadlineNanos: 1, file: Self.file)).ensureEnvironment()
        #expect(environment["CMUX_TUI_TRACE_STARTUP_FILE"] == nil)
        #expect(environment["CMUX_TUI_TRACE_STARTUP"] == "99") // only the provider's own value
    }

    @Test func noTraceAddsNothing() async {
        let environment = await launcher(nil).ensureEnvironment()
        #expect(environment["CMUX_TUI_TRACE_STARTUP_FILE"] == nil)
    }

    @Test func theSecondsLeftRoundUp() {
        let trace = DaemonStartupTrace(deadlineNanos: 10 * Self.second, file: Self.file)
        #expect(trace.environment(at: 6 * Self.second + 1) == ["CMUX_TUI_TRACE_STARTUP": "4",
                                                               "CMUX_TUI_TRACE_STARTUP_FILE": "/tmp/startup/startup-daemon.json"])
        #expect(trace.environment(at: 10 * Self.second - 1)["CMUX_TUI_TRACE_STARTUP"] == "1")
        #expect(trace.environment(at: 10 * Self.second).isEmpty)
    }
}
