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
    private var captures: [String: [String]]
    /// exit-success returned by `run`, keyed by tool path (default true).
    private let runResults: [String: Bool]

    init(captures: [String: String] = [:], runResults: [String: Bool] = [:]) {
        self.captures = captures.mapValues { [$0] }
        self.runResults = runResults
    }

    init(captureSequences: [String: [String]], runResults: [String: Bool] = [:]) {
        self.captures = captureSequences
        self.runResults = runResults
    }

    func run(_ tool: String, _ arguments: [String]) async -> Bool {
        calls.append(Call(tool: tool, arguments: arguments))
        return runResults[tool] ?? true
    }

    func capture(_ tool: String, _ arguments: [String]) async -> String? {
        calls.append(Call(tool: tool, arguments: arguments))
        guard var values = captures[tool], !values.isEmpty else { return nil }
        let value = values.removeFirst()
        captures[tool] = values
        return value
    }
}

private let caffeinateAssertions = """
Listed by owning process:
   pid 42(caffeinate): [0x000a] PreventUserIdleSystemSleep named: "caffeinate command-line tool"
"""

private let caffeinateCommandPath = "/usr/bin/caffeinate\n"

private let idleAssertions = """
Assertion status system-wide:
   PreventUserIdleSystemSleep     0
Listed by owning process:
No assertions.
"""

private let amphetamineAssertions = """
Listed by owning process:
   pid 99(Amphetamine): [0x000b] PreventUserIdleSystemSleep named: "User session"
"""

@Suite("MacPowerController")
struct MacPowerControllerTests {
    @Test func keepAwakeStatusParsesPmsetCapture() async {
        let runner = FakeRunner(captures: ["/usr/bin/pmset": caffeinateAssertions])
        let status = await MacPowerController(runner: runner).keepAwakeStatus()
        #expect(status?.caffeinateRunning == true)
        #expect(status?.keptAwake == true)
        #expect(await runner.calls == [.init(tool: "/usr/bin/pmset", arguments: ["-g", "assertions"])])
    }

    @Test func keepAwakeStatusIsUnknownWhenPmsetUnavailable() async {
        // No capture registered => capture returns nil, not a fake all-clear.
        let runner = FakeRunner()
        let status = await MacPowerController(runner: runner).keepAwakeStatus()
        #expect(status == nil)
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

    @Test func systemRunnerTimesOutHungCommand() async {
        let runner = SystemMacPowerCommandRunner(timeout: 0.2)
        let ok = await runner.run("/bin/sh", ["-c", "sleep 5"])
        #expect(ok == false)
    }

    @Test func disableKeepAwakeKillsCaffeinateThenRereadsStatus() async throws {
        let runner = FakeRunner(captureSequences: [
            "/usr/bin/pmset": [caffeinateAssertions, idleAssertions],
            "/bin/ps": [caffeinateCommandPath],
        ], runResults: ["/bin/kill": true])
        let maybeOutcome = await MacPowerController(runner: runner).disableKeepAwake()
        let outcome = try #require(maybeOutcome)
        #expect(outcome.terminatedCaffeinate)
        #expect(outcome.status == .idle)
        // Only the observed caffeinate holder PID is revalidated and signaled before the re-read.
        #expect(await runner.calls == [
            .init(tool: "/usr/bin/pmset", arguments: ["-g", "assertions"]),
            .init(tool: "/bin/ps", arguments: ["-p", "42", "-o", "comm="]),
            .init(tool: "/bin/kill", arguments: ["42"]),
            .init(tool: "/usr/bin/pmset", arguments: ["-g", "assertions"]),
        ])
    }

    @Test func disableKeepAwakeSkipsKillWhenPidNoLongerBelongsToCaffeinate() async throws {
        let runner = FakeRunner(captureSequences: [
            "/usr/bin/pmset": [caffeinateAssertions, idleAssertions],
            "/bin/ps": ["/bin/zsh\n"],
        ], runResults: ["/bin/kill": true])
        let maybeOutcome = await MacPowerController(runner: runner).disableKeepAwake()
        let outcome = try #require(maybeOutcome)
        #expect(outcome.terminatedCaffeinate == false)
        #expect(outcome.status == .idle)
        #expect(await runner.calls == [
            .init(tool: "/usr/bin/pmset", arguments: ["-g", "assertions"]),
            .init(tool: "/bin/ps", arguments: ["-p", "42", "-o", "comm="]),
            .init(tool: "/usr/bin/pmset", arguments: ["-g", "assertions"]),
        ])
    }

    @Test func disableKeepAwakeReportsNothingTerminatedWhenNoCaffeinate() async throws {
        let runner = FakeRunner(captures: ["/usr/bin/pmset": amphetamineAssertions])
        let maybeOutcome = await MacPowerController(runner: runner).disableKeepAwake()
        let outcome = try #require(maybeOutcome)
        #expect(outcome.terminatedCaffeinate == false)
        #expect(outcome.status.caffeinateRunning == false)
        #expect(outcome.status.keptAwake)
        #expect(await runner.calls == [
            .init(tool: "/usr/bin/pmset", arguments: ["-g", "assertions"]),
        ])
    }
}
