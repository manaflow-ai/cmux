import Testing

@testable import CmuxMacPower

/// Records every command the controller runs and returns canned results, so the
/// controller's behavior can be exercised without touching the real machine. An
/// actor so it is `Sendable` and async-safe under Swift 6 strict concurrency.
private actor FakeRunner: MacPowerCommandRunning {
    struct Call: Equatable {
        let tool: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    /// stdout returned by `capture`, keyed by tool path.
    private let captures: [String: String]
    /// exit-success returned by `run`, keyed by tool path (default true).
    private let runResults: [String: Bool]

    init(captures: [String: String] = [:], runResults: [String: Bool] = [:]) {
        self.captures = captures
        self.runResults = runResults
    }

    func run(_ tool: String, _ arguments: [String]) async -> Bool {
        calls.append(Call(tool: tool, arguments: arguments))
        return runResults[tool] ?? true
    }

    func capture(_ tool: String, _ arguments: [String]) async -> String? {
        calls.append(Call(tool: tool, arguments: arguments))
        return captures[tool]
    }
}

private let caffeinateAssertions = """
Listed by owning process:
   pid 42(caffeinate): [0x000a] PreventUserIdleSystemSleep named: "caffeinate command-line tool"
"""

private let idleAssertions = """
Assertion status system-wide:
   PreventUserIdleSystemSleep     0
Listed by owning process:
No assertions.
"""

@Suite("MacPowerController")
struct MacPowerControllerTests {
    @Test func keepAwakeStatusParsesPmsetCapture() async {
        let runner = FakeRunner(captures: ["/usr/bin/pmset": caffeinateAssertions])
        let status = await MacPowerController(runner: runner).keepAwakeStatus()
        #expect(status.caffeinateRunning)
        #expect(status.keptAwake)
        #expect(await runner.calls == [.init(tool: "/usr/bin/pmset", arguments: ["-g", "assertions"])])
    }

    @Test func keepAwakeStatusIsIdleWhenPmsetUnavailable() async {
        // No capture registered => capture returns nil => idle, not a crash.
        let runner = FakeRunner()
        let status = await MacPowerController(runner: runner).keepAwakeStatus()
        #expect(status == .idle)
    }

    @Test func sleepSystemRunsSystemEventsAppleScript() async {
        let runner = FakeRunner()
        let ok = await MacPowerController(runner: runner).sleepSystem()
        #expect(ok)
        let call = await runner.calls.first
        #expect(call?.tool == "/usr/bin/osascript")
        #expect(call?.arguments == ["-e", "tell application \"System Events\" to sleep"])
    }

    @Test func sleepSystemReportsFailureWhenCommandFails() async {
        // Simulates automation not yet granted: osascript exits non-zero.
        let runner = FakeRunner(runResults: ["/usr/bin/osascript": false])
        let ok = await MacPowerController(runner: runner).sleepSystem()
        #expect(ok == false)
    }

    @Test func disableKeepAwakeKillsCaffeinateThenRereadsStatus() async {
        let runner = FakeRunner(
            captures: ["/usr/bin/pmset": idleAssertions],
            runResults: ["/usr/bin/pkill": true]
        )
        let outcome = await MacPowerController(runner: runner).disableKeepAwake()
        #expect(outcome.terminatedCaffeinate)
        #expect(outcome.status == .idle)
        // pkill must run before the status re-read.
        #expect(await runner.calls == [
            .init(tool: "/usr/bin/pkill", arguments: ["-x", "caffeinate"]),
            .init(tool: "/usr/bin/pmset", arguments: ["-g", "assertions"]),
        ])
    }

    @Test func disableKeepAwakeReportsNothingTerminatedWhenNoCaffeinate() async {
        // pkill exit 1 (no match) => terminatedCaffeinate false; the re-read still
        // returns whatever else is keeping the Mac awake.
        let runner = FakeRunner(
            captures: ["/usr/bin/pmset": caffeinateAssertions],
            runResults: ["/usr/bin/pkill": false]
        )
        let outcome = await MacPowerController(runner: runner).disableKeepAwake()
        #expect(outcome.terminatedCaffeinate == false)
        #expect(outcome.status.caffeinateRunning)
    }
}
