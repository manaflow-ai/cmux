@testable import CmuxMacPower

/// Records every command the controller runs and returns canned results so
/// controller behavior can be exercised without touching the real machine.
actor FakeMacPowerCommandRunner: MacPowerCommandRunning {
    private(set) var calls: [FakeMacPowerCommandRunnerCall] = []
    private var captures: [String: [String]]
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
        calls.append(FakeMacPowerCommandRunnerCall(tool: tool, arguments: arguments))
        return runResults[tool] ?? true
    }

    func capture(_ tool: String, _ arguments: [String]) async -> String? {
        calls.append(FakeMacPowerCommandRunnerCall(tool: tool, arguments: arguments))
        guard var values = captures[tool], !values.isEmpty else { return nil }
        let value = values.removeFirst()
        captures[tool] = values
        return value
    }
}
