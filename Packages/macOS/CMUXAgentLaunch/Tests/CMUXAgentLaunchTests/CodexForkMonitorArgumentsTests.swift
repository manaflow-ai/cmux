import CMUXAgentLaunch
import Testing

@Suite("CodexForkMonitorArguments")
struct CodexForkMonitorArgumentsTests {
    @Test("forwards fork ownership values")
    func forwardsOwnershipValues() {
        #expect(CodexForkMonitorArguments().make(environment: [
            "CMUX_AGENT_FORK_PARENT_SESSION_ID": "parent-session",
            "CMUX_AGENT_FORK_LAUNCH_ID": "launch-id",
            "CMUX_CODEX_PID": "1234",
        ]) == [
            "--fork-parent", "parent-session",
            "--fork-launch-id", "launch-id",
            "--fork-owner-pid", "1234",
        ])
    }

    @Test("omits optional values when absent")
    func omitsOptionalValuesWhenAbsent() {
        #expect(CodexForkMonitorArguments().make(environment: [
            "CMUX_AGENT_FORK_PARENT_SESSION_ID": "parent-session",
        ]) == ["--fork-parent", "parent-session"])
        #expect(CodexForkMonitorArguments().make(environment: [:]).isEmpty)
    }
}
