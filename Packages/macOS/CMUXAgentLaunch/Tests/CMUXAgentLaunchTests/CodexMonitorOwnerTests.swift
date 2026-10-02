import Testing
@testable import CMUXAgentLaunch

struct CodexForkMonitorArgumentTests {
    @Test
    func forwardsForkParentClaimToDetachedMonitor() {
        let owner = CodexMonitorOwner(environment: [
            "CMUX_AGENT_FORK_PARENT_SESSION_ID": "parent-session",
            "CMUX_AGENT_FORK_LAUNCH_ID": "launch-id",
            "CMUX_CODEX_PID": "1234",
        ])
        let arguments = owner.forkMonitorArguments()

        #expect(arguments == [
            "--fork-parent", "parent-session",
            "--fork-launch-id", "launch-id",
            "--fork-owner-pid", "1234",
        ])
    }

    @Test
    func omitsForkArgumentsForNormalCodexMonitor() {
        #expect(CodexMonitorOwner(environment: [:]).forkMonitorArguments().isEmpty)
    }
}
