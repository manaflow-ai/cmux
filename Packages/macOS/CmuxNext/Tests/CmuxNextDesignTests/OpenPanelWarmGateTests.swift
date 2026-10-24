@testable import CmuxNextDesign
import Testing

/// When the app's open-panel warm-up may make an `NSOpenPanel` (review 2 of pl-fleet-gui). The session read is the
/// console-user rule of bench_launch.py and the hq worker gate, injected here so the rule is checked without a
/// running app or a console session.
@MainActor
@Suite struct OpenPanelWarmGateTests {
    private static func gate(running: Bool = true, onConsole: Bool = true, idle: Bool = true) -> OpenPanelWarmGate {
        OpenPanelWarmGate(appIsRunning: { running }, sessionIsOnConsole: { onConsole }, personIsIdle: { idle })
    }

    @Test func aRunningAppOffTheConsoleSessionNeverWarms() {
        guard case .never = Self.gate(onConsole: false).check() else {
            Issue.record("a running app whose account is not the console user may make a panel")
            return
        }
    }

    @Test func aProcessThatNeverRanTheEventLoopNeverWarms() {
        guard case .never = Self.gate(running: false).check() else {
            Issue.record("a process with no event loop may make a panel")
            return
        }
    }

    @Test func onTheConsoleAPauseWarmsAndInputWaits() {
        #expect(Self.gate().check() == .ready)
        #expect(Self.gate(idle: false).check() == .busy)
    }

    /// The session is read only for a running app, and the person's input only on the console: a check stops at the
    /// first fact that says no.
    @Test func theGateReadsNoMoreThanItNeeds() {
        let reads = Reads()
        let gate = OpenPanelWarmGate(appIsRunning: { reads.list.append("running"); return true },
                                     sessionIsOnConsole: { reads.list.append("console"); return false },
                                     personIsIdle: { reads.list.append("idle"); return true })
        _ = gate.check()
        #expect(reads.list == ["running", "console"])
    }

    /// The facts a gate read, in order.
    @MainActor private final class Reads {
        var list: [String] = []
    }
}
