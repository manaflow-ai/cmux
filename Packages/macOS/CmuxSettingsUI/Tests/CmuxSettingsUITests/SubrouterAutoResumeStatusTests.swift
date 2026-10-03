import Testing
@testable import CmuxSettingsUI

@Suite("SubrouterAutoResumeStatus")
struct SubrouterAutoResumeStatusTests {
    @Test func parsesBothAgents() {
        let status = SubrouterAutoResumeStatus.parse(
            output: "claude auto-resume: enabled\ncodex auto-resume: disabled\nworker: running\nalarms: 0 scheduled or firing\n",
            exitStatus: 0
        )
        #expect(status == SubrouterAutoResumeStatus(availability: .available, claudeEnabled: true, codexEnabled: false))
    }

    @Test func olderSubrouterIsUnsupported() {
        // An sr that predates auto-resume rejects the command.
        let status = SubrouterAutoResumeStatus.parse(output: "subrouter: unknown command \"auto-resume\"\n", exitStatus: 2)
        #expect(status.availability == .unsupported)
        // One that exits 0 without per-agent lines is no better.
        #expect(SubrouterAutoResumeStatus.parse(output: "ok\n", exitStatus: 0).availability == .unsupported)
    }

    @Test func otherFailuresCarryTheirMessage() {
        let status = SubrouterAutoResumeStatus.parse(output: "subrouter: load wake config: permission denied\n", exitStatus: 1)
        #expect(status.availability == .failed("subrouter: load wake config: permission denied"))
        #expect(!status.isEnabled(.claude) && !status.isEnabled(.codex))
    }
}
